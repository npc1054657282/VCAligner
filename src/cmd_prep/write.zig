const std = @import("std");
const PrepRunner = @import("PrepRunner.zig");
const c = @import("gvca").c_helper.c;

pub fn task(ctx: *PrepRunner) void {
    // 写线程本地分配器。都是c分配器。
    const allocator = std.heap.c_allocator;
    // rocksdb相关对象创建的C API内部是`new`，走的C++异常机制，不会把错误结果传播，因此判空无意义。
    const db_options = c.rocksdb_options_create().?;
    defer c.rocksdb_options_destroy(db_options);
    if (ctx.n_rocksdbjobs) |n_rocksdbjobs| {
        c.rocksdb_options_increase_parallelism(db_options, n_rocksdbjobs);
    }
    c.rocksdb_options_prepare_for_bulk_load(db_options);
    c.rocksdb_options_set_create_if_missing(db_options, 1);
    c.rocksdb_options_set_error_if_exists(db_options, 1); // 如果db已存在，报错。
    // 默认列族以path-id为前缀。目前path-id设计为usize。不使用布隆过滤器，因为后续使用数据库的时候基本没有需要检查无效的key的情况。
    const prefix = c.rocksdb_slicetransform_create_fixed_prefix(@sizeOf(usize)).?;
    defer c.rocksdb_slicetransform_destroy(prefix);
    c.rocksdb_options_set_prefix_extractor(db_options, prefix);
    // 默认列族需要merge operator，在后面追加commit。
    var merge_operator: FixedBinaryAppendMergeOperater = undefined;
    merge_operator.init(allocator);
    defer merge_operator.deinit();
    c.rocksdb_options_set_merge_operator(db_options, merge_operator.op);
    var err_cstr: ?[*:0]u8 = null;
    const db = c.rocksdb_open(db_options, ctx.rocksdb_output, @ptrCast(&err_cstr)).?;
    if (err_cstr) |ecstr| {
        std.log.err("rocksdb create failed! {s}\n", .{std.mem.span(ecstr)});
        std.process.abort();
    }
    defer c.rocksdb_close(db);
    // 默认列族：键是path_index-blob，值由多个commit_index组成，需要前缀提取器。
    const cf_pi_b_cis = c.rocksdb_get_default_column_family_handle(db).?;
    defer c.rocksdb_column_family_handle_destroy(cf_pi_b_cis);
    // 为其它列族设置单独的默认配置（它们不需要前缀提取器）
    const cf_options = c.rocksdb_options_create().?;
    defer c.rocksdb_options_destroy(cf_options);
    // 键 commit_index - 值 commit 列族
    const cf_ci_c = c.rocksdb_create_column_family(db, cf_options, "ci2c", @ptrCast(&err_cstr)).?;
    if (err_cstr) |ecstr| {
        std.log.err("rocksdb create column family 'ci2c' failed! {s}\n", .{std.mem.span(ecstr)});
        std.process.abort();
    }
    defer c.rocksdb_column_family_handle_destroy(cf_ci_c);
    // 键 path_index - 值 path 列族
    const cf_pi_p = c.rocksdb_create_column_family(db, cf_options, "pi2p", @ptrCast(&err_cstr)).?;
    if (err_cstr) |ecstr| {
        std.log.err("rocksdb create column family 'ci2c' failed! {s}\n", .{std.mem.span(ecstr)});
        std.process.abort();
    }
    defer c.rocksdb_column_family_handle_destroy(cf_pi_p);
    // 键 path_rank - 值 path_index 列族
    const cf_pr_pi = c.rocksdb_create_column_family(db, cf_options, "pr2pi", @ptrCast(&err_cstr)).?;
    if (err_cstr) |ecstr| {
        std.log.err("rocksdb create column family 'ci2c' failed! {s}\n", .{std.mem.span(ecstr)});
        std.process.abort();
    }
    defer c.rocksdb_column_family_handle_destroy(cf_pr_pi);

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

const FixedBinaryAppendMergeOperater = struct {
    op: *c.rocksdb_mergeoperator_t,
    state: MemPools,
    const MemPools = struct {
        pool1: std.heap.MemoryPoolExtra([8]u8, .{}),
        pool2: std.heap.MemoryPoolExtra([16]u8, .{}),
        pool4: std.heap.MemoryPoolExtra([32]u8, .{}),
        pool8: std.heap.MemoryPoolExtra([64]u8, .{}),
        pool16: std.heap.MemoryPoolExtra([128]u8, .{}),
        pool32: std.heap.MemoryPoolExtra([256]u8, .{}),
        pool64: std.heap.MemoryPoolExtra([512]u8, .{}),
        pool128: std.heap.MemoryPoolExtra([1024]u8, .{}),
        pool256: std.heap.MemoryPoolExtra([2048]u8, .{}),
        pool512: std.heap.MemoryPoolExtra([4096]u8, .{}),
        allocator: std.mem.Allocator,
        fn init(allocator: std.mem.Allocator) MemPools {
            return .{
                .pool1 = .init(allocator),
                .pool2 = .init(allocator),
                .pool4 = .init(allocator),
                .pool8 = .init(allocator),
                .pool16 = .init(allocator),
                .pool32 = .init(allocator),
                .pool64 = .init(allocator),
                .pool128 = .init(allocator),
                .pool256 = .init(allocator),
                .pool512 = .init(allocator),
                .allocator = allocator,
            };
        }
        fn deinit(self: *MemPools) void {
            self.pool1.deinit();
            self.pool2.deinit();
            self.pool4.deinit();
            self.pool8.deinit();
            self.pool16.deinit();
            self.pool32.deinit();
            self.pool64.deinit();
            self.pool128.deinit();
            self.pool256.deinit();
            self.pool512.deinit();
        }
        fn create(self: *MemPools, len: usize) ![]u8 {
            const fitlen = std.math.ceilPowerOfTwo(usize, len) catch unreachable;
            return switch (fitlen) {
                8 => try self.pool1.create(),
                16 => try self.pool2.create(),
                32 => try self.pool4.create(),
                64 => try self.pool8.create(),
                128 => try self.pool16.create(),
                256 => try self.pool32.create(),
                512 => try self.pool64.create(),
                1024 => try self.pool128.create(),
                2048 => try self.pool256.create(),
                4096 => try self.pool512.create(),
                else => try self.allocator.alloc(u8, len),
            };
        }
        fn destroy(self: *MemPools, ptr: [*c]u8, len: usize) void {
            const fitlen = std.math.ceilPowerOfTwo(usize, len) catch unreachable;
            switch (fitlen) {
                8 => self.pool1.destroy(@ptrCast(@alignCast(ptr))),
                16 => self.pool2.destroy(@ptrCast(@alignCast(ptr))),
                32 => self.pool4.destroy(@ptrCast(@alignCast(ptr))),
                64 => self.pool8.destroy(@ptrCast(@alignCast(ptr))),
                128 => self.pool16.destroy(@ptrCast(@alignCast(ptr))),
                256 => self.pool32.destroy(@ptrCast(@alignCast(ptr))),
                512 => self.pool64.destroy(@ptrCast(@alignCast(ptr))),
                1024 => self.pool128.destroy(@ptrCast(@alignCast(ptr))),
                2048 => self.pool256.destroy(@ptrCast(@alignCast(ptr))),
                4096 => self.pool512.destroy(@ptrCast(@alignCast(ptr))),
                else => self.allocator.free(ptr),
            }
        }
    };
    fn init(self: *FixedBinaryAppendMergeOperater, allocator: std.mem.Allocator) void {
        self.* = .{
            .op = c.rocksdb_mergeoperator_create(
                &self.state,
                null,
                fullMerge,
                // 不设置部分合并。部分合并会增加多个小对象分配。完整对象栈的合并因为减少了内存分配量反而更高效。
                // 但不确定部分合并有没有可能可以减少内存用量以提升效率。如果发现有此瓶颈可能考虑设置部分合并。
                // [参考](https://github.com/johnzeng/rocksdb-doc-cn/blob/master/doc/Merge-Operator-Implementation.md#%E6%95%88%E7%8E%87%E7%9B%B8%E5%85%B3%E7%9A%84%E7%AC%94%E8%AE%B0)
                null,
                deleteValue,
                name,
            ).?,
            .state = .init(allocator),
        };
    }
    fn deinit(self: *FixedBinaryAppendMergeOperater) void {
        c.rocksdb_mergeoperator_destroy(self.op);
        self.state.deinit();
        self.* = undefined;
    }
    fn fullMerge(
        state: ?*anyopaque,
        key: [*c]const u8,
        key_length: usize,
        existing_value: [*c]const u8,
        existing_value_length: usize,
        operands_list: [*c]const [*c]const u8,
        operands_list_length: [*c]const usize,
        num_operands: c_int,
        success: [*c]u8,
        new_value_length: [*c]usize,
    ) callconv(.c) [*c]u8 {
        const mem_pools: *MemPools = @ptrCast(@alignCast(state.?));
        _ = key;
        _ = key_length;
        const total_length = blk: {
            var tlen = if (existing_value != null) existing_value_length else 0;
            for (0..@intCast(num_operands)) |i| {
                tlen += operands_list_length[i];
            }
            break :blk tlen;
        };
        const result = mem_pools.create(total_length) catch {
            std.log.err("mem pool create failed! lotal length is {d}\n", .{total_length});
            success.* = 0;
            return null;
        };

        var offset: usize = 0;
        if (existing_value != null) {
            @memcpy(result[offset..].ptr, existing_value[0..existing_value_length]);
            offset += existing_value_length;
        }
        for (0..@intCast(num_operands)) |i| {
            const operand = operands_list[i];
            const operand_len = operands_list_length[i];
            @memcpy(result[offset..].ptr, operand[0..operand_len]);
            offset += operand_len;
        }
        new_value_length.* = total_length;
        success.* = 1;
        return result.ptr;
    }
    fn deleteValue(state: ?*anyopaque, value: [*c]const u8, value_length: usize) callconv(.c) void {
        const mem_pools: *MemPools = @ptrCast(@alignCast(state.?));
        // 神秘API设计：`deleteValue`钩子居然要求是个`const`指针，差点让我以为我用错了。检察源码发现居然真就是这么用的。
        mem_pools.destroy(@constCast(value), value_length);
    }
    fn name(state: ?*anyopaque) callconv(.c) [*c]const u8 {
        _ = state;
        return "FixedBinaryAppendMergeOperater";
    }
};
