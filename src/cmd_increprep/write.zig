const std = @import("std");
const vcaligner = @import("vcaligner");
const c_helper = vcaligner.c_helper;
const c = c_helper.c;
const Channel = @import("preprocess.zig").Channel;
const MsgToWriter = @import("preprocess.zig").MsgToWriter;
const Parsed = @import("preprocess.zig").Parsed;
const writer_bound_registries = @import("preprocess.zig").writer_bound_registries;

const storage = @import("storage.zig");

pub fn writeCumulative(
    storage_handles: storage.Handles.Cumulative,
    channel: *Channel,
    registries: writer_bound_registries.Handle,
    write_batch_watermark: c_int,
    last_diag: *vcaligner.diag.Diagnostic,
) !void {
    writing: {
        const woptions = blk: {
            const woptions = c.rocksdb_writeoptions_create();
            // 无论是全量还是增量，都关闭WAL。因为libgit2的`git_odb_foreach`固有的顺序不确定性，无论如何，WAL都无法做到逻辑可靠的断电续传。
            // 或者说，基于WAL的断电续传需要更复杂的设计才能支持。我们目前仅仅基于checkpoint来确保可靠性，不考虑增量的断电续传能力。
            c.rocksdb_writeoptions_disable_WAL(woptions, 1);
            break :blk woptions.?;
        };
        defer c.rocksdb_writeoptions_destroy(woptions);
        const wb = c.rocksdb_writebatch_create().?;
        defer c.rocksdb_writebatch_destroy(wb);
        var consumer_local = channel.mpsc_queue_ref.initConsumerLocal();
        while (channel.claimConsume(&consumer_local, null)) |lease| {
            const ticket, const msg: *MsgToWriter = lease;
            defer channel.releaseConsumedUnsafe(ticket);
            switch (msg.*) {
                .parsed => |*parsed| {
                    for (parsed.pairs.items) |*pair| {
                        const path_get_or_put_result = try registries.path_registry.map.getOrPut(registries.allocator, pair.path);
                        if (!path_get_or_put_result.found_existing) {
                            // 注意！`getOrPut`会直接把我们用于比较的`pair.path`作为键。但是`pair.path`的生存周期实际上并不够！
                            // 因此，我们需要重新设置一个生命周期安全的新key，也就是将当前的`pair.path`重新拷贝一份。为了这些键的拷贝，采用专为此设计的`key_arena`。
                            // 虽然文档让我们不要修改键，但我想我知道我们现在在做什么。
                            path_get_or_put_result.key_ptr.* = try registries.path_registry.key_arena.allocator().dupe(u8, pair.path);
                            path_get_or_put_result.value_ptr.* = .{
                                .index = .fromNative(@intCast(path_get_or_put_result.index)),
                                .blob_cnt = 0, // 接下来很快会因为`blob_path_registry不命中而增加至1。
                            };
                            c.rocksdb_writebatch_put_cf(
                                wb,
                                storage_handles.cfs.get(.pi2p),
                                @ptrCast(&path_get_or_put_result.value_ptr.index),
                                @sizeOf(vcaligner.rocksdb_custom.PathSeq),
                                @ptrCast(path_get_or_put_result.key_ptr.ptr),
                                path_get_or_put_result.key_ptr.len,
                            );
                        }
                        const blob_path_key: vcaligner.rocksdb_custom.BlobPathKey = .{
                            .blob_hash = pair.blob_hash,
                            .path_seq = path_get_or_put_result.value_ptr.index,
                        };
                        const blob_path_get_or_put_result = try registries.blob_path_registry.map.getOrPut(registries.allocator, blob_path_key);
                        if (!blob_path_get_or_put_result.found_existing) {
                            // 如果不存在，map的count会立刻加1。我们实际的index从0开始算，所以index是count - 1。
                            blob_path_get_or_put_result.value_ptr.* = .fromNative(registries.blob_path_registry.map.count() - 1);
                            // 如果这是一个新的path-blob组合，path的blob_cnt立即加1。
                            path_get_or_put_result.value_ptr.blob_cnt += 1;
                            c.rocksdb_writebatch_put_cf(
                                wb,
                                storage_handles.cfs.get(.b_pi2bpi),
                                @ptrCast(blob_path_get_or_put_result.key_ptr),
                                @sizeOf(vcaligner.rocksdb_custom.BlobPathKey),
                                @ptrCast(blob_path_get_or_put_result.value_ptr),
                                @sizeOf(vcaligner.rocksdb_custom.BlobPathSeq),
                            );
                        }
                        // writebatch的put是深拷贝，key传入指针以后其生存周期就允许结束。
                        const key: vcaligner.rocksdb_custom.Key = .{
                            .blob_path_seq = blob_path_get_or_put_result.value_ptr.*,
                            .commit_seq = parsed.commit_seq,
                        };
                        c.rocksdb_writebatch_put_cf(
                            wb,
                            storage_handles.cfs.get(.bpi2ci),
                            @ptrCast(&key),
                            @sizeOf(vcaligner.rocksdb_custom.Key),
                            null,
                            0,
                        );
                    }
                    parsed.deinit();
                },
                .commit_meta => |*commit_metas| {
                    // XXX: 写入可以确保顺序，将来可能考虑使用SstFileWriter写入。
                    for (commit_metas.batch.items) |*commit_meta| {
                        c.rocksdb_writebatch_put_cf(
                            wb,
                            storage_handles.cfs.get(.ci2c),
                            @ptrCast(&commit_meta.commit_seq),
                            @sizeOf(vcaligner.rocksdb_custom.CommitSeq),
                            @ptrCast(&commit_meta.commit_hash.id),
                            @sizeOf(@TypeOf(commit_meta.commit_hash.id)),
                        );
                    }
                    commit_metas.deinit();
                },
            }
            if (c.rocksdb_writebatch_count(wb) > write_batch_watermark) {
                var err_cstr: ?[*:0]u8 = null;
                c.rocksdb_write(storage_handles.db, woptions, wb, @ptrCast(&err_cstr));
                try c_helper.checkRocksdbErr(err_cstr, @src(), last_diag);
                c.rocksdb_writebatch_clear(wb);
            }
        } else |_| {
            var err_cstr: ?[*:0]u8 = null;
            c.rocksdb_write(storage_handles.db, woptions, wb, @ptrCast(&err_cstr));
            try c_helper.checkRocksdbErr(err_cstr, @src(), last_diag);
            c.rocksdb_writebatch_clear(wb);
            std.log.debug("Parse end.\n", .{});
        }
        break :writing;
    }
    // 确保可能写入的列族全部刷新到磁盘。
    // NOTE: 不论是否当前是prepare for bulk load，不论是否需要修改数据库配置，都应该这么做。
    // 写入pr_bc2pi列族使用SstFileWriter，不要在列族数据没有排空前使用它。
    flush_all: {
        const foptions = c.rocksdb_flushoptions_create().?;
        defer c.rocksdb_flushoptions_destroy(foptions);
        c.rocksdb_flushoptions_set_wait(foptions, 1);
        var err_cstr: ?[*:0]u8 = null;
        // NOTE: 此处constCast是rocksdb的API问题所致，实际上此API绝无可能修改传入的列族family值。
        // 一说rocksdb这么设计是为了兼容古老编译器。
        c.rocksdb_flush_cfs(storage_handles.db, foptions, @constCast(&storage_handles.cfs.values), storage_handles.cfs.values.len, @ptrCast(&err_cstr));
        try c_helper.checkRocksdbErr(err_cstr, @src(), last_diag);
        break :flush_all;
    }
}

pub fn writePrBc2Pi(
    db: *c.rocksdb_t,
    cf_pr_bc2pi: vcaligner.rocksdb_custom.CollumFamily.Handle(.pr_bc2pi),
    path_registry: *writer_bound_registries.PathRegistry.Map,
    tmp_sst_file_path: [:0]const u8,
    compression: bool,
    last_diag: *vcaligner.diag.Diagnostic,
) !void {
    sort_path_registry: {
        const SortContext = struct {
            map: *const writer_bound_registries.PathRegistry.Map,
            pub fn lessThan(sctx: @This(), a_index: usize, b_index: usize) bool {
                // 基于值中的 blob_cnt 比较。采用降序，符号翻转。
                return sctx.map.values()[a_index].blob_cnt > sctx.map.values()[b_index].blob_cnt;
            }
        };
        const sctx: SortContext = .{ .map = path_registry };
        path_registry.sort(sctx);
        break :sort_path_registry;
    }
    sst_file_write: {
        const sst_file_writer = sst_file_writer: {
            const env = c.rocksdb_envoptions_create().?;
            defer c.rocksdb_envoptions_destroy(env);
            const options = blk: {
                const options = c.rocksdb_options_create().?;
                storage.applyPrBc2PiCfOptions(options, compression);
                break :blk options;
            };
            const sst_file_writer = c.rocksdb_sstfilewriter_create(env, options);
            break :sst_file_writer sst_file_writer;
        };
        defer c.rocksdb_sstfilewriter_destroy(sst_file_writer);
        var err_cstr: ?[*:0]u8 = null;
        c.rocksdb_sstfilewriter_open(sst_file_writer, tmp_sst_file_path.ptr, @ptrCast(&err_cstr));
        try c_helper.checkRocksdbErr(err_cstr, @src(), last_diag);
        // 遍历排序后的`path_registry`，写入sst
        var iter = path_registry.iterator();
        var path_rank: vcaligner.rocksdb_custom.PathRank = undefined;
        while (do: {
            path_rank = .fromNative(@intCast(iter.index));
            break :do iter.next();
        }) |entry| {
            // sstfilewriter每次put以后，key和value的生存期即可结束，不需要长期维持生存期
            const key: vcaligner.rocksdb_custom.PathRankBlobCountKey = .{
                .path_rank = path_rank,
                .blob_count = .fromNative(entry.value_ptr.blob_cnt),
            };
            c.rocksdb_sstfilewriter_put(
                sst_file_writer,
                @ptrCast(&key),
                @sizeOf(vcaligner.rocksdb_custom.PathRankBlobCountKey),
                @ptrCast(&entry.value_ptr.index),
                @sizeOf(vcaligner.rocksdb_custom.PathSeq),
                @ptrCast(&err_cstr),
            );
            try c_helper.checkRocksdbErr(err_cstr, @src(), last_diag);
        }
        c.rocksdb_sstfilewriter_finish(sst_file_writer, @ptrCast(&err_cstr));
        try c_helper.checkRocksdbErr(err_cstr, @src(), last_diag);
        break :sst_file_write;
    }
    // 将sst文件导入列族
    sst_file_ingest: {
        const iefoptions = blk: {
            const iefoptions = c.rocksdb_ingestexternalfileoptions_create();
            // NOTE: 接收到警告`At least one SST file opened without unique ID to verify`，后跟`global_seqno=0`
            // 由于我们采用sst file writer方案，无法使用常规写入引入的校验机制，这个警告很正常，可忽略。
            // 而global seqno=0也很正常，并非警告。
            // 不要为此去设置`allow_global_seqno`，这个用于sst file之间如果存在重叠的情况，故使用全局序号以试图标记重叠的先后版本顺序。
            // 在我们的场景，没有使用他的需求。
            c.rocksdb_ingestexternalfileoptions_set_allow_global_seqno(iefoptions, 0);
            // 设置此项选项后，临时sst文件将自动在ingest后被删除，无需手动删除。
            c.rocksdb_ingestexternalfileoptions_set_move_files(iefoptions, 1);
            break :blk iefoptions.?;
        };
        defer c.rocksdb_ingestexternalfileoptions_destroy(iefoptions);
        const file_list = [_][*:0]const u8{
            tmp_sst_file_path,
        };
        var err_cstr: ?[*:0]u8 = null;
        c.rocksdb_ingest_external_file_cf(db, cf_pr_bc2pi.handle, @ptrCast(&file_list), file_list.len, iefoptions, @ptrCast(&err_cstr));
        try c_helper.checkRocksdbErr(err_cstr, @src(), last_diag);
        break :sst_file_ingest;
    }
    // 无需对pr_bc2pi列族再进行一次全量compaction，原因见`storage.applyPrBc2PiCfOptions`内的注释。
}
