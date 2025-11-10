const std = @import("std");
const gvca = @import("gvca");
const c = gvca.c_helper.c;
const AnaRunner = @import("AnaRunner.zig");
const diag = gvca.diag;
const Pool = gvca.Pool;
const PathSeq = gvca.rocksdb_custom.PathSeq;
const PathBlobSeq = gvca.rocksdb_custom.PathBlobSeq;
const PathBlobKey = gvca.rocksdb_custom.PathBlobKey;
const CommitSeqNative = gvca.rocksdb_custom.CommitSeqNative;
const CommitSeq = gvca.rocksdb_custom.CommitSeq;
const Key = gvca.rocksdb_custom.Key;
const CommitRange = gvca.commit_range.CommitRange;

pub fn analysis(ctx: *AnaRunner, allocator: std.mem.Allocator, last_diag: *diag.Diagnostic) !void {
    _ = last_diag;
    var err_cstr: ?[*:0]u8 = null;
    const db_options = blk: {
        const db_options = c.rocksdb_options_create();
        c.rocksdb_options_optimize_for_point_lookup(db_options, ctx.point_lookup_cache_mb);
        // 以下为默认列族设置
        c.rocksdb_options_set_prefix_extractor(db_options, c.rocksdb_slicetransform_create_fixed_prefix(@sizeOf(PathBlobSeq)));
        break :blk db_options.?;
    };
    defer c.rocksdb_options_destroy(db_options);
    const cf_options = c.rocksdb_options_create().?;
    defer c.rocksdb_options_destroy(cf_options);
    ctx.db, ctx.cf_pbi_ci, ctx.cf_pi_p, ctx.cf_pi_b_pbi, const cf_ci_c, const cf_pr_pi = open_db: {
        const column_family_names = [_][*:0]const u8{
            "default",
            "pi2p",
            "pib2pbi",
            "ci2c",
            "pr2pi",
        };
        const column_family_options: [column_family_names.len]?*const c.rocksdb_options_t = .{
            db_options,
            cf_options,
            cf_options,
            cf_options,
            cf_options,
        };
        var column_family_handles: [column_family_names.len]?*c.rocksdb_column_family_handle_t = undefined;
        const new_db = c.rocksdb_open_for_read_only_column_families(
            db_options,
            ctx.rocksdb_path,
            column_family_names.len,
            @ptrCast(&column_family_names),
            &column_family_options,
            &column_family_handles,
            // TODO: 待排查：创建完rocksdb数据库以后总是遗留一个空的`.log`文件，导致判定wal文件存在。因此将这项报错关闭。
            0,
            @ptrCast(&err_cstr),
        );
        if (err_cstr) |ecstr| {
            std.log.err("rocksdb open failed! {s}\n", .{std.mem.span(ecstr)});
            return error.RocksdbError;
        }
        break :open_db .{
            new_db.?,
            column_family_handles[0].?,
            column_family_handles[1].?,
            column_family_handles[2].?,
            column_family_handles[3].?,
            column_family_handles[4].?,
        };
    };
    defer {
        c.rocksdb_column_family_handle_destroy(ctx.cf_pbi_ci);
        c.rocksdb_column_family_handle_destroy(ctx.cf_pi_p);
        c.rocksdb_column_family_handle_destroy(ctx.cf_pi_b_pbi);
        c.rocksdb_column_family_handle_destroy(cf_ci_c);
        c.rocksdb_column_family_handle_destroy(cf_pr_pi);
        c.rocksdb_close(ctx.db);
    }

    ctx.candidate_parser = .init();
    defer ctx.candidate_parser.deinit(allocator);
    // 一个agenda对应git仓库里的一个可能存在的路径。在创建时，它们已知seq，并很快将从数据库中解析得对应的path（只要rocksdb数据库是正确的，就一定能够解析）
    // 如果agenda解析后，可能有以下情况：1.在release包中找不到同名文件。2.在release包中找到了同名文件，但是发现release中构造的path-blob对在git仓库找不到对应。
    // 3.能够找到对应，此情况下一定能够得到一个commit非空集合。
    parse_agendas: {
        var pool: Pool = undefined;
        try pool.init(.{ .allocator = allocator, .n_jobs = ctx.n_jobs - 1 });
        var wait_group: std.Thread.WaitGroup = .{};
        defer {
            pool.waitAndWork(&wait_group);
            pool.deinit();
        }
        const pr2pi_roptions = blk: {
            const roptions = c.rocksdb_readoptions_create();
            // pr2pi是全局遍历一次，缓存没有意义，不使用缓存避免污染。
            c.rocksdb_readoptions_set_fill_cache(roptions, 0);
            // pr2pi是总序遍历，按全局键序遍历整个列族。
            c.rocksdb_readoptions_set_total_order_seek(roptions, 1);
            c.rocksdb_readoptions_set_auto_readahead_size(roptions, 1);
            // 为了让`readahead`实际生效，配置`iterate_upper_bound`为usize最大值。
            // [参见](https://github.com/facebook/rocksdb/blob/6a202c5570d9aca11a23c5b1a78019f8be245463/include/rocksdb/options.h#L2111-L2135)
            c.rocksdb_readoptions_set_iterate_upper_bound(roptions, "\xff\xff\xff\xff\xff\xff\xff\xff".ptr, @sizeOf(usize));
            break :blk roptions.?;
        };
        defer c.rocksdb_readoptions_destroy(pr2pi_roptions);
        const pi_iter = c.rocksdb_create_iterator_cf(ctx.db, pr2pi_roptions, cf_pr_pi).?;
        defer c.rocksdb_iter_destroy(pi_iter);
        c.rocksdb_iter_seek_to_first(pi_iter);
        while (c.rocksdb_iter_valid(pi_iter) != 0) {
            defer c.rocksdb_iter_next(pi_iter);
            const pi: PathSeq = blk: {
                var pi_len: usize = undefined;
                // `pi_ptr`是易失的，下一次迭代就会被释放。无需我手动释放
                const pi_ptr = c.rocksdb_iter_value(pi_iter, &pi_len);
                break :blk std.mem.bytesToValue(PathSeq, pi_ptr[0..pi_len]);
            };
            try ctx.candidate_parser.agenda_parsers.append(allocator, .{
                .pi = pi,
            });
        }
        for (0..ctx.candidate_parser.agenda_parsers.items.len) |i| {
            // 要求传入的分配器是线程安全的。
            pool.spawnWg(&wait_group, parse_agenda, .{ ctx, i, allocator });
        }
        break :parse_agendas;
    }
    std.log.info("start candidate.", .{});
    // agendas全部解析完毕。开始依次候选。
    for (ctx.candidate_parser.agenda_parsers.items, 0..) |*agenda, agenda_index| {
        switch (agenda.commit_collection) {
            .unparsed => unreachable,
            .path_not_find_in_release, .path_blob_not_match => {},
            .parsed => |commit_collection| {
                // 对于agendas，将它与目前已经存在的所有candidate进行运算。
                var intersection_success: bool = false;
                for (ctx.candidate_parser.candidates.items, 0..) |*candidate, candidate_index| {
                    fallthrough: switch (try candidate.commit_collection.intersectInPlace(allocator, commit_collection.view())) {
                        .restricted => {
                            try agenda.affect_candidates_idx.append(allocator, candidate_index);
                            continue :fallthrough .unchanged;
                        },
                        .unchanged => {
                            intersection_success = intersection_success or true;
                            try agenda.included_in_candidates_idx.append(allocator, candidate_index);
                        },
                        .empty => {},
                    }
                }
                // 如果所有交集皆为空，本agendas成为新候选人。把本agendas拷贝后创建为新的candidate。
                if (!intersection_success) {
                    std.log.info("append new candidate with path {s}", .{agenda.path.parsed});
                    const new_candidate_index = ctx.candidate_parser.candidates.items.len;
                    try ctx.candidate_parser.candidates.append(allocator, .{
                        .commit_collection = new_candidate_collection: {
                            var new_candidate_collection: gvca.commit_range.CommitCollection = try commit_collection.view().dupe(allocator);
                            // 对于新创建的候选集，重新补课，与前面的所有agenda取交集。
                            for (ctx.candidate_parser.agenda_parsers.items) |*review_agenda| {
                                if (agenda == review_agenda) {
                                    try agenda.affect_candidates_idx.append(allocator, new_candidate_index);
                                    try agenda.included_in_candidates_idx.append(allocator, new_candidate_index);
                                    break;
                                }
                                switch (review_agenda.commit_collection) {
                                    .unparsed => unreachable,
                                    .path_not_find_in_release, .path_blob_not_match => {},
                                    .parsed => |reviw_commit_collection| {
                                        fallthrough: switch (try new_candidate_collection.intersectInPlace(allocator, reviw_commit_collection.view())) {
                                            .restricted => {
                                                try agenda.affect_candidates_idx.append(allocator, new_candidate_index);
                                                continue :fallthrough .unchanged;
                                            },
                                            .unchanged => try agenda.included_in_candidates_idx.append(allocator, new_candidate_index),
                                            .empty => {},
                                        }
                                    },
                                }
                            }
                            break :new_candidate_collection new_candidate_collection;
                        },
                        .created_by_agenda_idx = agenda_index,
                    });
                }
            },
        }
    }

    // 最后：对于所有candidate，解析其所有commits的实际值。
    for (ctx.candidate_parser.candidates.items) |*candidate| {
        for (candidate.commit_collection.ranges) |range| {
            const ci_native_start = range.start;
            const ci_native_end = range.end;
            var ci_native = ci_native_start;
            while (ci_native <= ci_native_end) {
                defer ci_native += 1;
                const ci: CommitSeq = .fromNative(ci_native);
                const commit: c.git_oid = blk: {
                    var vallen: usize = undefined;
                    const commit_ptr = c.rocksdb_get_cf(
                        ctx.db,
                        ctx.candidate_parser.once_get_roptions,
                        cf_ci_c,
                        @ptrCast(&ci),
                        @sizeOf(CommitSeq),
                        &vallen,
                        @ptrCast(&err_cstr),
                    );
                    if (err_cstr) |ecstr| {
                        std.log.err("rocksdb commit get failed! {s}", .{std.mem.span(ecstr)});
                        gvca.crash_dump.dumpAndCrash(@src());
                    }
                    if (commit_ptr == null) {
                        // 对应的commit不存在
                        std.log.err("rocksdb commit seq {d} not found!", .{ci_native});
                        gvca.crash_dump.dumpAndCrash(@src());
                    }
                    defer c.rocksdb_free(commit_ptr);
                    break :blk .{
                        .id = std.mem.bytesToValue(@FieldType(c.git_oid, "id"), commit_ptr),
                    };
                };
                try candidate.parsed.append(allocator, commit);
            }
        }
    }
    // 用agenda_parsers解析得到的所有并非在release包找不到的文件，构造为一个StringHashmap以便于查找。利于构造release_phatom_files。
    // 所有key均采集自agenda_parses，不维护生存期
    var repo_paths_map: std.StringHashMapUnmanaged(void) = .empty;
    build_repo_paths_map: {
        for (ctx.candidate_parser.agenda_parsers.items) |*agenda| {
            switch (agenda.commit_collection) {
                .parsed, .path_blob_not_match => try repo_paths_map.put(allocator, agenda.path.parsed, {}),
                else => {},
            }
        }
        break :build_repo_paths_map;
    }
    defer repo_paths_map.deinit(allocator);
    // 最后输出。
    const f: std.fs.File = switch (ctx.report_output) {
        .manual => |report_output| try std.fs.cwd().createFileZ(report_output, .{}),
        .none => std.fs.File.stdout(),
    };
    defer switch (ctx.report_output) {
        .manual => f.close(),
        .none => {},
    };
    const arbitrary_buffer_size = 1024;
    var output_buffer: [arbitrary_buffer_size]u8 = undefined;
    var output_writer: std.fs.File.Writer = f.writer(&output_buffer);
    var stringifier: std.json.Stringify = .{ .writer = &output_writer.interface, .options = .{ .whitespace = .indent_4 } };
    output: {
        try stringifier.beginObject();
        defer stringifier.endObject() catch gvca.crash_dump.dumpAndCrash(@src());
        try stringifier.objectField("candidates");
        candidates: {
            try stringifier.beginArray();
            defer stringifier.endArray() catch gvca.crash_dump.dumpAndCrash(@src());
            for (ctx.candidate_parser.candidates.items, 0..) |*candidate, candidate_index| {
                try stringifier.beginObject();
                defer stringifier.endObject() catch gvca.crash_dump.dumpAndCrash(@src());
                try stringifier.objectField("idx");
                try stringifier.write(candidate_index);
                try stringifier.objectField("created_by");
                try stringifier.write(ctx.candidate_parser.agenda_parsers.items[candidate.created_by_agenda_idx].path);
                try stringifier.objectField("commits");
                commits: {
                    try stringifier.beginArray();
                    defer stringifier.endArray() catch gvca.crash_dump.dumpAndCrash(@src());
                    for (candidate.parsed.items) |commit| {
                        try stringifier.write(std.fmt.bytesToHex(commit.id, .lower));
                    }
                    break :commits;
                }
            }
            break :candidates;
        }
        try stringifier.objectField("repo_only_files");
        repo_only_files: {
            try stringifier.beginArray();
            defer stringifier.endArray() catch gvca.crash_dump.dumpAndCrash(@src());
            for (ctx.candidate_parser.agenda_parsers.items) |*agenda| {
                switch (agenda.commit_collection) {
                    .path_not_find_in_release => try stringifier.write(agenda.path.parsed),
                    else => {},
                }
            }
            break :repo_only_files;
        }
        try stringifier.objectField("release_phatom_files");
        release_phatom_files: {
            try stringifier.beginArray();
            defer stringifier.endArray() catch gvca.crash_dump.dumpAndCrash(@src());
            // 遍历release目录，检查该子目录是否存在于repo_paths_map中
            var release_dir = try std.fs.cwd().openDirZ(ctx.release_path, .{ .iterate = true });
            defer release_dir.close();
            var walker = try release_dir.walk(allocator);
            while (try walker.next()) |entry| {
                if (entry.kind == .directory) continue;
                if (repo_paths_map.contains(entry.path)) continue;
                try stringifier.write(entry.path);
            }
            break :release_phatom_files;
        }
        try stringifier.objectField("dismatch_phatom_files");
        dismatch_phatom_files: {
            try stringifier.beginArray();
            defer stringifier.endArray() catch gvca.crash_dump.dumpAndCrash(@src());
            for (ctx.candidate_parser.agenda_parsers.items) |*agenda| {
                switch (agenda.commit_collection) {
                    .path_blob_not_match => try stringifier.write(agenda.path.parsed),
                    else => {},
                }
            }
            break :dismatch_phatom_files;
        }
        try stringifier.objectField("match_files");
        match_files: {
            try stringifier.beginArray();
            defer stringifier.endArray() catch gvca.crash_dump.dumpAndCrash(@src());
            for (ctx.candidate_parser.agenda_parsers.items) |*agenda| {
                switch (agenda.commit_collection) {
                    .parsed => {
                        try stringifier.beginObject();
                        defer stringifier.endObject() catch gvca.crash_dump.dumpAndCrash(@src());
                        try stringifier.objectField("path");
                        try stringifier.write(agenda.path.parsed);
                        try stringifier.objectField("affect_candidates_idx");
                        affect_candidates_idx: {
                            try stringifier.beginArray();
                            defer stringifier.endArray() catch gvca.crash_dump.dumpAndCrash(@src());
                            for (agenda.affect_candidates_idx.items) |candidate_idx| {
                                try stringifier.write(candidate_idx);
                            }
                            break :affect_candidates_idx;
                        }
                        try stringifier.objectField("included_in_candidates_idx");
                        included_in_candidates_idx: {
                            try stringifier.beginArray();
                            defer stringifier.endArray() catch gvca.crash_dump.dumpAndCrash(@src());
                            for (agenda.included_in_candidates_idx.items) |candidate_idx| {
                                try stringifier.write(candidate_idx);
                            }
                            break :included_in_candidates_idx;
                        }
                    },
                    else => {},
                }
            }
            break :match_files;
        }
        break :output;
    }
    try output_writer.interface.flush();
}

fn parse_agenda(gctx: *AnaRunner, agenda_index: usize, ts_allocator: std.mem.Allocator) void {
    const lctx = &gctx.candidate_parser.agenda_parsers.items[agenda_index];
    var err_cstr: ?[*:0]u8 = null;
    const release_path: [:0]u8, const path: [:0]u8 = blk: {
        var path_len: usize = undefined;
        const path_ptr = c.rocksdb_get_cf(
            gctx.db,
            gctx.candidate_parser.once_get_roptions,
            gctx.cf_pi_p,
            @ptrCast(&lctx.pi),
            @sizeOf(PathSeq),
            &path_len,
            @ptrCast(&err_cstr),
        );
        if (err_cstr) |ecstr| {
            std.log.err("rocksdb path get failed! {s}", .{std.mem.span(ecstr)});
            gvca.crash_dump.dumpAndCrash(@src());
        }
        if (path_ptr == null) {
            std.log.err("rocksdb path seq {d} not found!", .{lctx.pi.toNative()});
            gvca.crash_dump.dumpAndCrash(@src());
        }
        defer c.rocksdb_free(path_ptr);
        var builder: std.ArrayList(u8) = .empty;
        builder.appendSlice(ts_allocator, gctx.release_path) catch gvca.crash_dump.dumpAndCrash(@src());
        builder.append(ts_allocator, '/') catch gvca.crash_dump.dumpAndCrash(@src());
        builder.appendSlice(ts_allocator, path_ptr[0..path_len]) catch gvca.crash_dump.dumpAndCrash(@src());
        break :blk .{
            builder.toOwnedSliceSentinel(ts_allocator, 0) catch gvca.crash_dump.dumpAndCrash(@src()),
            ts_allocator.dupeZ(u8, path_ptr[0..path_len]) catch gvca.crash_dump.dumpAndCrash(@src()),
        };
    };
    defer {
        ts_allocator.free(release_path);
        lctx.path = .{ .parsed = path };
    }
    // 检查文件存在性。若存在，计算其hash。
    const path_blob_key: PathBlobKey = .{
        .path_seq = lctx.pi,
        .blob_hash = blk: {
            const maybe_blob_hash = gitBlobSha1Hash(ts_allocator, release_path) catch |err| {
                std.log.err("{s}", .{@errorName(err)});
                gvca.crash_dump.dumpAndCrash(@src());
            };
            if (maybe_blob_hash) |blob_hash| {
                break :blk blob_hash;
            }
            // 如果不存在，直接结束。
            lctx.commit_collection = .path_not_find_in_release;
            return;
        },
    };
    // 基于`path_blob_key`查询`path_blob_seq`
    const path_blob_seq: PathBlobSeq = blk: {
        var vallen: usize = undefined;
        const path_blob_seq_ptr = c.rocksdb_get_cf(
            gctx.db,
            gctx.candidate_parser.once_get_roptions,
            gctx.cf_pi_b_pbi,
            @ptrCast(&path_blob_key),
            @sizeOf(PathBlobKey),
            &vallen,
            @ptrCast(&err_cstr),
        );
        if (err_cstr) |ecstr| {
            std.log.err("rocksdb path blob seq get failed! {s}", .{std.mem.span(ecstr)});
            gvca.crash_dump.dumpAndCrash(@src());
        }
        if (path_blob_seq_ptr == null) {
            // 对应的blob不存在，直接结束。
            lctx.commit_collection = .path_blob_not_match;
            return;
        }
        defer c.rocksdb_free(path_blob_seq_ptr);
        break :blk std.mem.bytesToValue(PathBlobSeq, path_blob_seq_ptr);
    };
    // 将`path_blob_seq`作为前缀查找所有commit。
    lctx.commit_collection = commit_collection: {
        var builder: gvca.commit_range.CommitCollection.Builder = .init;
        const pbici_iter = c.rocksdb_create_iterator_cf(gctx.db, gctx.candidate_parser.prefix_scan_roptions, gctx.cf_pbi_ci).?;
        defer c.rocksdb_iter_destroy(pbici_iter);
        c.rocksdb_iter_seek(pbici_iter, @ptrCast(&path_blob_seq), @sizeOf(PathBlobSeq));
        while (c.rocksdb_iter_valid(pbici_iter) != 0) {
            defer c.rocksdb_iter_next(pbici_iter);
            const ci_native: CommitSeqNative = blk: {
                var klen: usize = undefined;
                const key_ptr = c.rocksdb_iter_key(pbici_iter, &klen);
                const ci: CommitSeq = std.mem.bytesAsValue(Key, key_ptr[0..klen]).commit_seq;
                break :blk ci.toNative();
            };
            // std.log.debug("find file {s} blob {x} commitseq {d}", .{ path, path_blob_key.blob_hash.id, ci_native });
            builder.appendAssumeGreaterNative(ts_allocator, ci_native) catch gvca.crash_dump.dumpAndCrash(@src());
        }
        // 此处不能用`.fromBuilder(...) catch`的写法，[参见](https://github.com/ziglang/zig/issues/21289)
        break :commit_collection .{ .parsed = builder.toOwnedCommitRanges(ts_allocator) catch |err| {
            switch (err) {
                error.EmptyCommitRanges => {
                    std.log.err("Cannot find any commit with path '{s}' blob {x} pathblobseq {d}", .{
                        path,
                        path_blob_key.blob_hash.id,
                        path_blob_seq.toNative(),
                    });
                },
                else => {},
            }
            gvca.crash_dump.dumpAndCrash(@src());
        } };
    };
}

// 模拟计算git的Sha1 blob hash。
fn gitBlobSha1Hash(allocator: std.mem.Allocator, path: [:0]const u8) !?c.git_oid {
    const file_or_sym_link: union(enum) {
        file: std.fs.File,
        sym_link: void,
    } = blk: {
        // 对于git而言，文件的符号链接不应当跟随打开，而是直接基于符号链接文件内容计算blob hash。
        // 由于zig标准库中的`Dir.openFileZ`系列函数无法指定不跟随符号链接，因此不使用此高级API
        // 分别使用posix API与windows API来指定不跟随符号链接的文件打开。
        switch (@import("builtin").os.tag) {
            // NOTE：NTFS系统的符号链接只有在git设置`core.symlinks=true`的情况下才与POSIX符号链接相互转译。
            // 默认情况下`core.symlinks=false`，这导致如果直接将windows的NTFS符号链接读取为普通文件，
            // git收录的blob将成为一个空文件。[`core.symlinks=true`是更安全的推荐配置。](https://www.joshkel.com/2018/01/18/symlinks-in-windows/)
            // 因此，尽管默认`core.symlinks=false`，当我们在windows下遇到了符号链接文件时，依旧优先读取它的符号链接路径并计算blob hash
            // 我们有理由做如下假设：如果一个windows的release包里还有NTFS的符号链接文件，
            // 那么我们相信如果该文件在仓库中也存在，那么仓库一定开启了`core.symlinks=true`
            // 换一个角度做假设：在windows系统上，如果解压一个来自linux系统的包，若结果出现符号链接，则可以相信该符号链接如果在原始git仓库存在，
            // 则一定是以posix符号链接的形式保存。
            .windows => {
                const path_w = try std.os.windows.cStrToPrefixedFileW(std.fs.cwd().fd, path);
                const file: std.fs.File = .{
                    .handle = std.os.windows.OpenFile(path_w, .{ .follow_symlinks = false }) catch |err| {
                        switch (err) {
                            // NOTE: 在windows系统下，OpenFile默认情况对于目录文件会抛出IsDir错误（与linux等系统行为不同）
                            // 存在一种情况：曾经仓库里存在这个文件路径，但现在不存在了，且这个路径变成了一个目录。
                            // 因此对于文件路径实际是目录的情况，当做与`FileNotFound`同等处理即可。
                            // 此外，windows系统下对于一些linux文件无法访问，例如`con`、`nul`。
                            // 这些文件在调试模式会直接导致unreachable，而在release模式导致Unexpected。在此放弃访问作为workaround。
                            // XXX: 考虑事先对文件名进行一次过滤，对于其中出现非法字符的文件事先滤掉，保证debug模式不会崩溃。
                            error.FileNotFound, error.IsDir, error.Unexpected => return null,
                            else => return err,
                        }
                    },
                };
                errdefer file.close();
                const stat = try file.stat();
                break :blk switch (stat.kind) {
                    .sym_link => sym_link: {
                        file.close();
                        break :sym_link .sym_link;
                    },
                    .file => .{ .file = file },
                    else => unreachable,
                };
            },
            else => {
                // 对于posix系统，我们有`fstatat`来事先确定文件状态。
                // 对于`fstatat`，如果设置`flag`为`AT.SYMLINK_NOFOLLOW`，它的行为与linux的`lstat`相同，但`lstat`不是posix标准，不能跨平台，
                // 而`fstatat`跨平台性能更好。
                const stat = std.posix.fstatatZ(std.fs.cwd().fd, path, std.posix.AT.SYMLINK_NOFOLLOW) catch |err| {
                    switch (err) {
                        error.FileNotFound => return null,
                        else => return err,
                    }
                };
                break :blk switch (stat.mode & std.posix.S.IFMT) {
                    // 目录。存在一种情况：曾经仓库里存在这个文件路径，但现在不存在了，且这个路径变成了一个目录。
                    // 因此对于文件路径实际是目录的情况，当做与`FileNotFound`同等处理即可。
                    std.posix.S.IFDIR => return null,
                    // 符号链接
                    std.posix.S.IFLNK => .sym_link,
                    // 普通文件
                    std.posix.S.IFREG => .{ .file = try std.fs.cwd().openFileZ(path, .{}) },
                    else => unreachable,
                };
            },
        }
    };
    defer switch (file_or_sym_link) {
        .file => |file| file.close(),
        .sym_link => {},
    };

    var hasher: std.crypto.hash.Sha1 = .init(.{});
    // 8192可以确保容纳所有路径长度（linux最大路径一般为4096，windows一般为512），且本身也是一个比较合适的文件读取缓冲区节点，适用于计算hash。
    var buffer: [8192]u8 = undefined;
    switch (file_or_sym_link) {
        .sym_link => {
            const link = try std.fs.cwd().readLinkZ(path, &buffer);
            const prefix = try std.fmt.allocPrint(allocator, "blob {}\x00", .{link.len});
            defer allocator.free(prefix);
            hasher.update(prefix);
            hasher.update(link);
        },
        .file => |file| {
            const file_size = try file.getEndPos();
            const prefix = try std.fmt.allocPrint(allocator, "blob {}\x00", .{file_size});
            defer allocator.free(prefix);
            hasher.update(prefix);
            while (true) {
                const bytes_read = try file.read(&buffer);
                if (bytes_read == 0) break;
                hasher.update(buffer[0..bytes_read]);
            }
        },
    }
    return .{ .id = hasher.finalResult() };
}

// 第一步：读取pr2pi列族和pi2p列族，获得一个path和pi的有序列表。
// 第二步：遍历该列表，下发子任务：
// 二·一找release_path中是否存在对应路径。
// 二·二：找到对应路径的文件，若存在，将release_path下的对应文件进行hash。
// 二·三，根据hash结果，通过pib2pbi寻找是否存在对应的blob id。
// 二·四：读取default，根据path-blob对前缀匹配，获得所有键，归并为一个commit id range 列表。
// 第三步：所有子任务执行完成以后，我们得到的是一个commit id range列表的[序列]。现在我们再设置一类commit id range列表的output[集合]。
// 遍历[序列]，不断将序列的当前commit id range列表与[集合]里的所有commit id range列表取交集。交集为空认为失败。
// 如果全部没有交集，当前的commit id range列表成为[集合]的一个新成员。显然，所有集合都是互不相交的。
