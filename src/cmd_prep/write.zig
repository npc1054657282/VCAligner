const std = @import("std");
const PrepRunner = @import("PrepRunner.zig");
const c = @import("gvca").c_helper.c;

pub fn task(ctx: *PrepRunner) void {
    // rocksdb相关对象创建的C API内部是`new`，走的C++异常机制，不会把错误结果传播，因此判空无意义。
    const db_options = c.rocksdb_options_create().?;
    defer c.rocksdb_options_destroy(db_options);
    if (ctx.n_rocksdbjobs) |n_rocksdbjobs| {
        c.rocksdb_options_increase_parallelism(db_options, n_rocksdbjobs);
    }
    c.rocksdb_options_prepare_for_bulk_load(db_options);
    c.rocksdb_options_set_create_if_missing(db_options, 1);
    c.rocksdb_options_set_error_if_exists(db_options, 1); // 如果db已存在，报错。
    // 设计默认列族的前缀过滤器：直至`\0`为止的都是前缀，指代路径。
    var prefix_extractor: NullTerminatedPrefixExtractor = undefined;
    prefix_extractor.init();
    defer prefix_extractor.deinit();
    c.rocksdb_options_set_prefix_extractor(db_options, prefix_extractor.base);
    var err_cstr: ?[*:0]u8 = null;
    const db = c.rocksdb_open(db_options, ctx.rocksdb_output, @ptrCast(&err_cstr)).?;
    if (err_cstr) |ecstr| {
        std.log.err("rocksdb create failed! {s}\n", .{std.mem.span(ecstr)});
        std.process.abort();
    }

    defer c.rocksdb_close(db);
    const cf_p_b_ci = c.rocksdb_get_default_column_family_handle(db).?;
    defer c.rocksdb_column_family_handle_destroy(cf_p_b_ci);
    // 为 commit_index - commit 列族设置单独的默认配置（它不需要布隆过滤器）
    const cf_ci_c_options = c.rocksdb_options_create().?;
    defer c.rocksdb_options_destroy(cf_ci_c_options);
    const cf_ci_c = c.rocksdb_create_column_family(db, cf_ci_c_options, "ci2c", @ptrCast(&err_cstr)).?;
    if (err_cstr) |ecstr| {
        std.log.err("rocksdb create column family 'ci2c' failed! {s}\n", .{std.mem.span(ecstr)});
        std.process.abort();
    }
    defer c.rocksdb_column_family_handle_destroy(cf_ci_c);

    const woptions = c.rocksdb_writeoptions_create().?;
    defer c.rocksdb_writeoptions_destroy(woptions);
    c.rocksdb_writeoptions_disable_WAL(woptions, 1);

    const wb = c.rocksdb_writebatch_create().?;
    defer c.rocksdb_writebatch_destroy(wb);

    var consumer_local = ctx.channel.mpsc_queue_ref.initConsumerLocal();
    while (ctx.channel.claimConsume(&consumer_local, null)) |lease| {
        const ticket, const parsed = lease;
        defer ctx.channel.releaseConsumedUnsafe(ticket);
        _ = parsed;
    } else |_| {}
}

const NullTerminatedPrefixExtractor = struct {
    base: *c.rocksdb_slicetransform_t,
    state: struct {},
    fn init(self: *NullTerminatedPrefixExtractor) void {
        self.* = .{
            .base = c.rocksdb_slicetransform_create(
                &self.state,
                null,
                transform,
                in_domain,
                in_range,
                name,
            ).?,
            .state = .{},
        };
    }
    fn deinit(self: *NullTerminatedPrefixExtractor) void {
        c.rocksdb_slicetransform_destroy(self.base);
        self.* = undefined;
    }
    fn transform(state: ?*anyopaque, key: [*c]const u8, length: usize, dst_length: [*c]usize) callconv(.c) [*c]u8 {
        _ = state;
        // 找到第一个 \0 或使用整个键
        const key_slice = key[0..length];
        const prefix_len = blk: {
            const zero_pos = std.mem.indexOfScalar(u8, key_slice, 0);
            if (zero_pos) |p| {
                break :blk p + 1;
            } else break :blk length;
        };
        const result_ptr: [*]u8 = @ptrCast(std.c.malloc(prefix_len) orelse {
            std.log.err("c malloc failed", .{});
            std.process.abort();
        });
        // XXX: 此布隆过滤器会构造大量小内存。由于内存销毁责任是rocksdb端的普通`free`，因此只能普通分配，没法用其他方法优化。
        // 若未来此处有性能瓶颈，考虑不再使用此布隆过滤器。
        const result_slice = @as([*]u8, result_ptr)[0..prefix_len];
        @memcpy(result_slice, key);
        dst_length.* = prefix_len;

        return result_slice.ptr;
    }
    fn in_domain(_: ?*anyopaque, _: [*c]const u8, _: usize) callconv(.c) u8 {
        return 1; // 所有键都在域内
    }
    fn in_range(_: ?*anyopaque, _: [*c]const u8, _: usize) callconv(.c) u8 {
        return 1; // 允许包含'\0'
    }
    fn name(_: ?*anyopaque) callconv(.c) [*c]const u8 {
        return "NullTerminatedPrefixExtractor";
    }
};
