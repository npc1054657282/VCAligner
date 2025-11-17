// 本程序使用rocksdb过程中默认列族使用的merge operator。
// merge operator一般而言伴随数据库终生，虽然实际上一次完整的手动compaction以后，实际上数据库不应当再出现merge operator内容。
// 但处于保险起见，每次阅读时总是设置它们是更加安全的。
const std = @import("std");
const c = @import("c.zig").c;
const gvca = @import("gvca");
fn Seq(comptime Native: type, comptime e: std.builtin.Endian) type {
    return enum(Native) {
        _,
        pub const endian = e;
        pub fn fromNative(n: Native) @This() {
            return @enumFromInt(std.mem.nativeTo(Native, n, e));
        }
        pub fn toNative(self: @This()) Native {
            return std.mem.toNative(Native, @intFromEnum(self), e);
        }
    };
}
pub const CommitSeqNative = u32;
pub const CommitSeq = Seq(CommitSeqNative, .big);
// Array hash map的`count()`返回类型为`usize`，与`hash map`的`u32`有显著不同。这是因为涉及索引，用`usize`有很大方便。
// 但实际上pathSeq只需要`u32`足矣。
pub const PathSeqNative = u32;
pub const PathSeq = Seq(PathSeqNative, .big);
pub const BlobPathKey = extern struct {
    blob_hash: c.git_oid align(1),
    path_seq: PathSeq align(1),
};
pub const BlobPathSeqNative = u32;
pub const BlobPathSeq = Seq(BlobPathSeqNative, .big);
pub const Key = extern struct {
    blob_path_seq: BlobPathSeq align(1),
    commit_seq: CommitSeq align(1),
};
// 一个范围。高位是范围起始值。低位是范围结束值。
const commit_range = @import("commit_range.zig");
const CommitRange = commit_range.CommitRange;

// 内存池是多线程不安全的。理想的方式是每个有需求的线程维护一个线程池。
threadlocal var local_mempool: ?*MemPool = null;

const MemPool = struct {
    pool1: std.heap.MemoryPoolExtra([@sizeOf(CommitSeq) * 1]u8, .{}),
    pool2: std.heap.MemoryPoolExtra([@sizeOf(CommitSeq) * 2]u8, .{}),
    pool4: std.heap.MemoryPoolExtra([@sizeOf(CommitSeq) * 4]u8, .{}),
    pool8: std.heap.MemoryPoolExtra([@sizeOf(CommitSeq) * 8]u8, .{}),
    pool16: std.heap.MemoryPoolExtra([@sizeOf(CommitSeq) * 16]u8, .{}),
    pool32: std.heap.MemoryPoolExtra([@sizeOf(CommitSeq) * 32]u8, .{}),
    pool64: std.heap.MemoryPoolExtra([@sizeOf(CommitSeq) * 64]u8, .{}),
    pool128: std.heap.MemoryPoolExtra([@sizeOf(CommitSeq) * 128]u8, .{}),
    pool256: std.heap.MemoryPoolExtra([@sizeOf(CommitSeq) * 256]u8, .{}),
    pool512: std.heap.MemoryPoolExtra([@sizeOf(CommitSeq) * 512]u8, .{}),
    pool1024: std.heap.MemoryPoolExtra([@sizeOf(CommitSeq) * 1024]u8, .{}),
    pool2048: std.heap.MemoryPoolExtra([@sizeOf(CommitSeq) * 2048]u8, .{}),
    allocator: std.mem.Allocator,
    current_task_len: usize, // 各线程的内存池保存当前merge任务构造内存时的申请长度。根据merge operator的C API可知可行，因为实际上删除是立即进行的。
    pub fn init(allocator: std.mem.Allocator) MemPool {
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
            .pool1024 = .init(allocator),
            .pool2048 = .init(allocator),
            .allocator = allocator,
            .current_task_len = undefined,
        };
    }
    pub fn deinit(self: *MemPool) void {
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
        self.pool1024.deinit();
        self.pool2048.deinit();
    }
    fn create(self: *MemPool, len: usize) ![]u8 {
        const fitlen = std.math.ceilPowerOfTwo(usize, len) catch unreachable;
        return switch (fitlen) {
            @sizeOf(CommitSeq) * 1 => try self.pool1.create(),
            @sizeOf(CommitSeq) * 2 => try self.pool2.create(),
            @sizeOf(CommitSeq) * 4 => try self.pool4.create(),
            @sizeOf(CommitSeq) * 8 => try self.pool8.create(),
            @sizeOf(CommitSeq) * 16 => try self.pool16.create(),
            @sizeOf(CommitSeq) * 32 => try self.pool32.create(),
            @sizeOf(CommitSeq) * 64 => try self.pool64.create(),
            @sizeOf(CommitSeq) * 128 => try self.pool128.create(),
            @sizeOf(CommitSeq) * 256 => try self.pool256.create(),
            @sizeOf(CommitSeq) * 512 => try self.pool512.create(),
            @sizeOf(CommitSeq) * 1024 => try self.pool1024.create(),
            @sizeOf(CommitSeq) * 2048 => try self.pool2048.create(),
            else => try self.allocator.alloc(u8, len),
        };
    }
    fn destroy(self: *MemPool, ptr: [*c]u8, len: usize) void {
        const fitlen = std.math.ceilPowerOfTwo(usize, len) catch unreachable;
        switch (fitlen) {
            @sizeOf(CommitSeq) * 1 => self.pool1.destroy(@ptrCast(@alignCast(ptr))),
            @sizeOf(CommitSeq) * 2 => self.pool2.destroy(@ptrCast(@alignCast(ptr))),
            @sizeOf(CommitSeq) * 4 => self.pool4.destroy(@ptrCast(@alignCast(ptr))),
            @sizeOf(CommitSeq) * 8 => self.pool8.destroy(@ptrCast(@alignCast(ptr))),
            @sizeOf(CommitSeq) * 16 => self.pool16.destroy(@ptrCast(@alignCast(ptr))),
            @sizeOf(CommitSeq) * 32 => self.pool32.destroy(@ptrCast(@alignCast(ptr))),
            @sizeOf(CommitSeq) * 64 => self.pool64.destroy(@ptrCast(@alignCast(ptr))),
            @sizeOf(CommitSeq) * 128 => self.pool128.destroy(@ptrCast(@alignCast(ptr))),
            @sizeOf(CommitSeq) * 256 => self.pool256.destroy(@ptrCast(@alignCast(ptr))),
            @sizeOf(CommitSeq) * 512 => self.pool512.destroy(@ptrCast(@alignCast(ptr))),
            @sizeOf(CommitSeq) * 1024 => self.pool1024.destroy(@ptrCast(@alignCast(ptr))),
            @sizeOf(CommitSeq) * 2048 => self.pool2048.destroy(@ptrCast(@alignCast(ptr))),
            else => self.allocator.free(ptr[0..len]),
        }
    }
    fn logUsage(self: *MemPool) void {
        std.log.info("pool1: {d}", .{self.pool1.arena.queryCapacity()});
        std.log.info("pool2: {d}", .{self.pool2.arena.queryCapacity()});
        std.log.info("pool4: {d}", .{self.pool4.arena.queryCapacity()});
        std.log.info("pool8: {d}", .{self.pool8.arena.queryCapacity()});
        std.log.info("pool16: {d}", .{self.pool16.arena.queryCapacity()});
        std.log.info("pool32: {d}", .{self.pool32.arena.queryCapacity()});
        std.log.info("pool64: {d}", .{self.pool64.arena.queryCapacity()});
        std.log.info("pool128: {d}", .{self.pool128.arena.queryCapacity()});
        std.log.info("pool256: {d}", .{self.pool256.arena.queryCapacity()});
        std.log.info("pool512: {d}", .{self.pool512.arena.queryCapacity()});
        std.log.info("pool1024: {d}", .{self.pool1024.arena.queryCapacity()});
        std.log.info("pool2048: {d}", .{self.pool2048.arena.queryCapacity()});
    }
};

pub const CommitRangesMergeOperaterState = struct {
    failed: [0]u8, // 当失败的时候返回其指针。
    mutex: std.Thread.Mutex,
    mempool_registry: std.ArrayList(*MemPool),
    allocator: std.mem.Allocator,
    dumpable: gvca.CrashDump.Dumpable,
    pub fn init(self: *CommitRangesMergeOperaterState, allocator: std.mem.Allocator) !void {
        self.* = .{
            .failed = .{},
            .mutex = .{},
            .mempool_registry = .empty,
            .allocator = allocator,
            .dumpable = .{ .dumpFn = dumpFn },
        };
        try gvca.crash_dump.reg("mergeop", 0, &self.dumpable);
    }
    pub fn deinit(self: *CommitRangesMergeOperaterState) void {
        gvca.crash_dump.unreg("mergeop", 0);
        for (self.mempool_registry.items) |threadlocal_mempool| {
            threadlocal_mempool.deinit();
            self.allocator.destroy(threadlocal_mempool);
        }
        self.mempool_registry.deinit(self.allocator);
    }
    fn reg(self: *CommitRangesMergeOperaterState) !void {
        std.debug.assert(local_mempool == null);
        local_mempool = try self.allocator.create(MemPool);
        local_mempool.?.* = .init(gvca.getAllocator());
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.mempool_registry.append(self.allocator, local_mempool.?);
    }
    pub fn createCommitRangesMergeOperater(self: *CommitRangesMergeOperaterState) *c.rocksdb_mergeoperator_t {
        return c.rocksdb_mergeoperator_create(
            self,
            // destructor可以是空操作，但是不能没有。
            destructor,
            fullMerge,
            // 部分合并会增加多个小对象分配。完整对象栈的合并因为减少了内存分配量反而更高效。
            // 但是`partialMerge`的实现是必须的，而且C API没有合理的部分合并失败策略，只能正常实现。
            // [参考](https://github.com/johnzeng/rocksdb-doc-cn/blob/master/doc/Merge-Operator-Implementation.md#%E6%95%88%E7%8E%87%E7%9B%B8%E5%85%B3%E7%9A%84%E7%AC%94%E8%AE%B0)
            partialMerge,
            deleteValue,
            name,
        ).?;
    }
    fn destructor(state: ?*anyopaque) callconv(.c) void {
        _ = state;
        return;
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
        const s: *CommitRangesMergeOperaterState = @ptrCast(@alignCast(state.?));
        if (local_mempool == null) s.reg() catch {
            std.log.err("mem pool reg failed!\n", .{});
            gvca.crash_dump.dumpAndCrash(@src());
        };
        // 预估结果的最大大小：已存在的值的长度和所有操作数范围化后的总长度。
        // 已存在的值总是一组范围序列。操作数有两种可能：如果长度为一个CommitSeq，那么它是一个单独的数。如果超过，它也是一组范围序列。
        // 将一个数重复两次，它就成为一个最小范围序列。
        // 目前从向前兼容性考虑，CommitSeq是大端字节序保存的，对于单独的数需要一次转换。但是转换为range以后就不再以大端字节序保存了，太麻烦了。
        const worst_total_length = blk: {
            var tlen = if (existing_value != null) existing_value_length else 0;
            for (0..@intCast(num_operands)) |i| {
                const operand_len = operands_list_length[i];
                if (operand_len == @sizeOf(CommitSeq)) tlen += @sizeOf(CommitRange) else tlen += operand_len;
            }
            break :blk tlen;
        };
        // XXX: 使用最小堆+多路归并排序方案是一种替代，但是对于大量单独的数而言，可能反而是一种负担。目前采用直接平铺所有range的方案。
        const all_ranges_bytes = local_mempool.?.create(worst_total_length) catch {
            std.log.err("mem pool create all ranges bytes failed! worst lotal length is {d}, key is {x}", .{ worst_total_length, key[0..key_length] });
            gvca.crash_dump.dumpAndCrash(@src());
        };
        defer local_mempool.?.destroy(all_ranges_bytes.ptr, worst_total_length);
        var offset: usize = 0;
        if (existing_value != null) {
            @memcpy(all_ranges_bytes[offset..].ptr, existing_value[0..existing_value_length]);
            offset += existing_value_length;
        }
        for (0..@intCast(num_operands)) |i| {
            const operand = operands_list[i];
            const operand_len = operands_list_length[i];
            if (operand_len != @sizeOf(CommitSeq)) {
                @memcpy(all_ranges_bytes[offset..].ptr, operand[0..operand_len]);
                offset += operand_len;
            } else {
                const range: *CommitRange = @ptrCast(@alignCast(all_ranges_bytes[offset..].ptr));
                // 目前操作数的保存是大端字节序的，目前不修改其逻辑。
                const commit_seq_native: CommitSeqNative = std.mem.readInt(CommitSeqNative, @ptrCast(operand.?), CommitSeq.endian);
                // 移位是逻辑行为，不受具体本机字节序影响。
                range.* = .packStartEnd(commit_seq_native, commit_seq_native);
                offset += @sizeOf(CommitRange);
            }
        }
        const all_ranges: []CommitRange = blk: {
            const all_ranges_ptr: [*]CommitRange = @ptrCast(@alignCast(all_ranges_bytes.ptr));
            break :blk all_ranges_ptr[0..(worst_total_length / @sizeOf(CommitRange))];
        };
        std.sort.pdq(CommitRange, all_ranges, {}, commit_range.asc);
        const result = local_mempool.?.create(worst_total_length) catch {
            std.log.err("mem pool create result failed! worst lotal length is {d}, key is {x}", .{ worst_total_length, key[0..key_length] });
            gvca.crash_dump.dumpAndCrash(@src());
        };
        local_mempool.?.current_task_len = worst_total_length;
        var result_ranges_list: std.ArrayList(CommitRange) = blk: {
            const result_ranges_ptr: [*]CommitRange = @ptrCast(@alignCast(result.ptr));
            const result_ranges_slice = result_ranges_ptr[0..(worst_total_length / @sizeOf(CommitRange))];
            break :blk std.ArrayList(CommitRange).initBuffer(result_ranges_slice);
        };
        var maybe_last_range: ?CommitRange = null;
        for (all_ranges) |new_range| {
            if (maybe_last_range) |last_range| {
                const last_start = last_range.start;
                const last_end = last_range.end;
                const new_start = new_range.start;
                const new_end = new_range.end;
                std.debug.assert(new_start >= last_start);
                if (new_start > last_end + 1) {
                    result_ranges_list.appendAssumeCapacity(last_range);
                    maybe_last_range = new_range;
                } else if (new_end > last_end) {
                    maybe_last_range = .packStartEnd(last_start, new_end);
                } // 如果`new_end`不超过`last_end`，什么都不做。
            } else maybe_last_range = new_range;
        }
        if (maybe_last_range) |last_range| {
            result_ranges_list.appendAssumeCapacity(last_range);
        }
        new_value_length.* = result_ranges_list.items.len * @sizeOf(CommitRange);
        success.* = 1;
        return result.ptr;
    }
    fn partialMerge(
        state: ?*anyopaque,
        key: [*c]const u8,
        key_length: usize,
        operands_list: [*c]const [*c]const u8,
        operands_list_length: [*c]const usize,
        num_operands: c_int,
        success: [*c]u8,
        new_value_length: [*c]usize,
    ) callconv(.c) [*c]u8 {
        // 1.根据C语言的源码，`partialMerge`是不可不实现的，不实现就出问题。
        // 2.根据C语言源码，没有可靠的阻止`partialMerge`实现的失败策略，
        // 因为我看相关注释，如果想要阻止`partialMerge`，要求不改变`new_value`且返回失败。而C API源码实现不论是否成败都一定更新`new_value`。
        // 因此，只能尽可能让`partialMerge`成功，虽然每次这么做都需要一次大的内存拷贝，也属于无奈之举。
        return fullMerge(state, key, key_length, null, 0, operands_list, operands_list_length, num_operands, success, new_value_length);
    }
    fn deleteValue(state: ?*anyopaque, value: [*c]const u8, value_length: usize) callconv(.c) void {
        if (value_length == 0) return;
        _ = state;
        // 神秘API设计：`deleteValue`钩子居然要求是个`const`指针，差点让我以为我用错了。检察源码发现居然真就是这么用的。
        // 不要使用`value_length`，使用藏在`local_mempool`里的`current_task_len`。
        local_mempool.?.destroy(@constCast(value.?), local_mempool.?.current_task_len);
    }
    fn name(state: ?*anyopaque) callconv(.c) [*c]const u8 {
        _ = state;
        return "CommitRangesMergeOperater";
    }
    fn dumpFn(dumpable: *gvca.CrashDump.Dumpable) void {
        const state: *CommitRangesMergeOperaterState = @alignCast(@fieldParentPtr("dumpable", dumpable));
        for (state.mempool_registry.items, 0..) |threadlocal_mempool, id| {
            std.log.info("mempool usage -{d}", .{id});
            threadlocal_mempool.logUsage();
            // 内存池的泄露问题已排除，不打印详情了。
            // _ = threadlocal_mempool;
        }
    }
};
