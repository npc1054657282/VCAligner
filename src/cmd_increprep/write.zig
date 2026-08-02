const std = @import("std");
const vcaligner = @import("vcaligner");
const c_helper = vcaligner.c_helper;
const c = c_helper.c;
const Channel = @import("preprocess.zig").Channel;
const MsgToWriter = @import("preprocess.zig").MsgToWriter;
const Parsed = @import("preprocess.zig").Parsed;
const WriterBoundRegistries = @import("preprocess.zig").WriterBoundRegistries;

pub const CumulativeStorage = @import("storage.zig").Cumulative;

fn write(
    storage: CumulativeStorage,
    channel: *Channel,
    registries: *WriterBoundRegistries,
    write_batch_watermark: c_int,
    last_diag: *vcaligner.diag.Diagnostic,
) !void {
    writing: {
        const woptions = blk: {
            const woptions = c.rocksdb_writeoptions_create();
            // 无论是全量还是增量，都关闭WAL。因为libgit2的`git_odb_foreach`固有的顺序不确定性，无论如何，WAL都无法做到逻辑可靠的断电续传。
            // 或者说，基于WAL的断电续传需要更复杂的设计才能支持。我们目前仅仅基于checkpoint来确保可靠性，不考虑增量的断电续传能力。
            c.rocksdb_writeoptions_disable_WAL(1);
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
                        const path_get_or_put_result = try registries.path_registry.map.getOrPut(registries.allocator(), pair.path);
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
                                storage.cf_handles.get(.pi_p),
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
                        const blob_path_get_or_put_result = try registries.blob_path_registry.getOrPut(registries.allocator(), blob_path_key);
                        if (!blob_path_get_or_put_result.found_existing) {
                            // 如果不存在，map的count会立刻加1。我们实际的index从0开始算，所以index是count - 1。
                            blob_path_get_or_put_result.value_ptr.* = .fromNative(registries.blob_path_registry.count() - 1);
                            // 如果这是一个新的path-blob组合，path的blob_cnt立即加1。
                            path_get_or_put_result.value_ptr.blob_cnt += 1;
                            c.rocksdb_writebatch_put_cf(
                                wb,
                                storage.cf_handles.get(.b_pi_bpi),
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
                            storage.cf_handles.get(.bpi_ci),
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
                            storage.cf_handles.get(.ci_c),
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
                c.rocksdb_write(storage.db, woptions, wb, @ptrCast(&err_cstr));
                try c_helper.checkRocksdbErr(err_cstr, @src(), last_diag);
                c.rocksdb_writebatch_clear(wb);
            }
        }
        break :writing;
    }
    // 确保可能写入的列族全部刷新到磁盘。
    // NOTE: 不论是否当前是prepare for bulk load，不论是否需要修改数据库配置，都应该这么做。
    // 写入pr2pi列族使用SstFileWriter，不要在列族数据没有排空前使用它。
    flush_all: {
        const foptions = c.rocksdb_flushoptions_create().?;
        defer c.rocksdb_flushoptions_destroy(foptions);
        c.rocksdb_flushoptions_set_wait(foptions, 1);
        var err_cstr: ?[*:0]u8 = null;
        // NOTE: 此处constCast是rocksdb的API问题所致，实际上此API绝无可能修改传入的列族family值。
        // 一说rocksdb这么设计是为了兼容古老编译器。
        c.rocksdb_flush_cfs(storage.db, foptions, @constCast(&storage.cf_handles.values), storage.cf_handles.values.len, @ptrCast(&err_cstr));
        try c_helper.checkRocksdbErr(err_cstr, @src(), last_diag);
        break :flush_all;
    }
}
