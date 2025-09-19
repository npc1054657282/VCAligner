const std = @import("std");
const gvca = @import("gvca");
const c = gvca.c_helper.c;
const AnaRunner = @import("AnaRunner.zig");
const diag = gvca.diag;
const Pool = gvca.Pool;
const PathSeq = gvca.rocksdb_custom.PathSeq;
const PathBlobSeq = gvca.rocksdb_custom.PathBlobSeq;
const PathBlobKey = gvca.rocksdb_custom.PathBlobKey;
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
            try ctx.candidate_parser.agenda_parsers.append(allocator, .{ .pi = pi });
        }
        for (0..ctx.candidate_parser.agenda_parsers.items.len) |i| {
            // 要求传入的分配器是线程安全的。
            pool.spawnWg(&wait_group, parse_agenda, .{ ctx, i, allocator });
        }
        break :parse_agendas;
    }
    // agendas全部解析完毕。开始依次候选。
    for (ctx.candidate_parser.agenda_parsers.items) |*agenda| {
        if (agenda.maybe_commit_ranges) |commit_ranges| {
            // 对于agendas，将它与目前已经存在的所有candidate进行运算。
            var intersection_success: usize = 0;
            for (ctx.candidate_parser.candidates.items) |*candidate| {
                const updated: []CommitRange = try gvca.commit_range.intersection(allocator, candidate.commit_ranges, commit_ranges);
                if (updated.len == 0) {
                    // 交集为空，无操作。
                    allocator.free(updated);
                    continue;
                }
                // 交集非空，新交集替换原有candidate。
                allocator.free(candidate.commit_ranges);
                candidate.commit_ranges = updated;
                intersection_success += 1;
            }
            // 如果所有交集皆为空，本agendas成为新候选人。把本agendas拷贝后创建为新的candidate。
            if (intersection_success == 0) {
                try ctx.candidate_parser.candidates.append(
                    allocator,
                    .{
                        .commit_ranges = try allocator.dupe(CommitRange, commit_ranges),
                    },
                );
            }
            // 本agenda的commit_ranges使命完成，释放回归null。
            // XXX: 也可以不立即释放，到最后deinit的时候一起释放。
            allocator.free(commit_ranges);
            agenda.maybe_commit_ranges = null;
        }
        // 空范围直接跳过。
    }
    // 最后：对于所有candidate，打印其所有commits。
    std.debug.print("result output.\n", .{});
    for (ctx.candidate_parser.candidates.items) |*candidate| {
        for (candidate.commit_ranges) |range| {
            const ci_native_start = gvca.commit_range.getStart(range);
            const ci_native_end = gvca.commit_range.getEnd(range);
            var ci_native = ci_native_start;
            while (ci_native <= ci_native_end) {
                defer ci_native += 1;
                const ci = std.mem.nativeToBig(CommitSeq, ci_native);
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
                        gvca.crash_dump.dumpAndCrash();
                    }
                    if (commit_ptr == null) {
                        // 对应的commit不存在
                        std.log.err("rocksdb commit seq {d} not found!", .{ci_native});
                        gvca.crash_dump.dumpAndCrash();
                    }
                    defer c.rocksdb_free(commit_ptr);
                    break :blk .{
                        .id = std.mem.bytesToValue(@FieldType(c.git_oid, "id"), commit_ptr),
                    };
                };
                // TODO: 更加标准的写入，例如指定写入文件
                std.debug.print("{x}\n", .{commit.id});
            }
        }
    }
}

fn parse_agenda(gctx: *AnaRunner, agenda_index: usize, ts_allocator: std.mem.Allocator) void {
    const lctx = &gctx.candidate_parser.agenda_parsers.items[agenda_index];
    var err_cstr: ?[*:0]u8 = null;
    const path: [:0]u8 = blk: {
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
            gvca.crash_dump.dumpAndCrash();
        }
        if (path_ptr == null) {
            std.log.err("rocksdb path seq {d} not found!", .{std.mem.bigToNative(PathSeq, lctx.pi)});
            gvca.crash_dump.dumpAndCrash();
        }
        defer c.rocksdb_free(path_ptr);
        var builder: std.ArrayList(u8) = .empty;
        builder.appendSlice(ts_allocator, gctx.release_path) catch gvca.crash_dump.dumpAndCrash();
        builder.append(ts_allocator, '/') catch gvca.crash_dump.dumpAndCrash();
        builder.appendSlice(ts_allocator, path_ptr[0..path_len]) catch gvca.crash_dump.dumpAndCrash();
        break :blk builder.toOwnedSliceSentinel(ts_allocator, 0) catch gvca.crash_dump.dumpAndCrash();
    };
    defer ts_allocator.free(path);
    // 检查文件存在性。若存在，计算其hash。
    const path_blob_key: PathBlobKey = .{
        .path_seq = lctx.pi,
        .blob_hash = blk: {
            const maybe_blob_hash = gitBlobSha1Hash(ts_allocator, path) catch gvca.crash_dump.dumpAndCrash();
            if (maybe_blob_hash) |blob_hash| {
                break :blk blob_hash;
            }
            // 如果不存在，直接结束。
            lctx.maybe_commit_ranges = null;
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
            gvca.crash_dump.dumpAndCrash();
        }
        if (path_blob_seq_ptr == null) {
            // 对应的blob不存在，直接结束。
            lctx.maybe_commit_ranges = null;
            return;
        }
        defer c.rocksdb_free(path_blob_seq_ptr);
        break :blk std.mem.bytesToValue(PathBlobSeq, path_blob_seq_ptr);
    };
    // 将`path_blob_seq`作为前缀查找所有commit。
    lctx.maybe_commit_ranges = commit_ranges: {
        var commit_ranges: std.ArrayList(CommitRange) = .empty;
        var maybe_last_range: ?CommitRange = null;
        const pbici_iter = c.rocksdb_create_iterator_cf(gctx.db, gctx.candidate_parser.prefix_scan_roptions, gctx.cf_pbi_ci).?;
        defer c.rocksdb_iter_destroy(pbici_iter);
        c.rocksdb_iter_seek(pbici_iter, @ptrCast(&path_blob_seq), @sizeOf(PathBlobSeq));
        while (c.rocksdb_iter_valid(pbici_iter) != 0) {
            defer c.rocksdb_iter_next(pbici_iter);
            const ci_native: gvca.commit_range.CommitSeqNative = blk: {
                var klen: usize = undefined;
                const key_ptr = c.rocksdb_iter_key(pbici_iter, &klen);
                const ci: CommitSeq = std.mem.bytesAsValue(Key, key_ptr[0..klen]).commit_seq;
                break :blk std.mem.bigToNative(CommitSeq, ci);
            };
            std.log.debug("find file {s} blob {x} commitseq {d}", .{ path, path_blob_key.blob_hash.id, ci_native });
            if (maybe_last_range) |last_range| {
                const last_start = gvca.commit_range.getStart(last_range);
                const last_end = gvca.commit_range.getEnd(last_range);
                std.debug.assert(ci_native > last_start and last_end >= last_start);
                if (ci_native == last_end + 1) {
                    maybe_last_range = gvca.commit_range.packStartEnd(last_start, ci_native);
                } else {
                    commit_ranges.append(ts_allocator, last_range) catch gvca.crash_dump.dumpAndCrash();
                    maybe_last_range = gvca.commit_range.packStartEnd(ci_native, ci_native);
                }
            } else maybe_last_range = gvca.commit_range.packStartEnd(ci_native, ci_native);
        }
        if (maybe_last_range) |last_range| {
            commit_ranges.append(ts_allocator, last_range) catch gvca.crash_dump.dumpAndCrash();
        } else {
            std.log.err("Cannot find any commit with path '{s}' blob {x} pathblobseq {d}", .{
                path,
                path_blob_key.blob_hash.id,
                std.mem.bigToNative(PathBlobSeq, path_blob_seq),
            });
            gvca.crash_dump.dumpAndCrash();
        }
        break :commit_ranges commit_ranges.toOwnedSlice(ts_allocator) catch gvca.crash_dump.dumpAndCrash();
    };
}

// 模拟计算git的Sha1 blob hash。
fn gitBlobSha1Hash(allocator: std.mem.Allocator, path: [:0]const u8) !?c.git_oid {
    std.fs.cwd().accessZ(path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            return null;
        }
        return err; // 不存在文件返回null。其他错误上抛。
    };
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const file_size = try file.getEndPos();
    // 构造 Git blob 前缀 "blob <size>\0"
    const prefix = try std.fmt.allocPrint(allocator, "blob {}\x00", .{file_size});
    defer allocator.free(prefix);
    var hasher: std.crypto.hash.Sha1 = .init(.{});
    hasher.update(prefix);
    var buffer: [8192]u8 = undefined;
    while (true) {
        const bytes_read = try file.read(&buffer);
        if (bytes_read == 0) break;
        hasher.update(buffer[0..bytes_read]);
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
