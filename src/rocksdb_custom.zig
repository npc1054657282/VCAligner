// 本程序使用rocksdb过程中默认列族使用的merge operator。
// merge operator一般而言伴随数据库终生，虽然实际上一次完整的手动compaction以后，实际上数据库不应当再出现merge operator内容。
// 但处于保险起见，每次阅读时总是设置它们是更加安全的。
const std = @import("std");
const c = @import("c.zig").c;
const gvca = @import("gvca");
pub const CommitSeq = @import("cmd_prep/PrepRunner.zig").CommitSeq;
pub const PathSeq = @import("cmd_prep/PrepRunner.zig").PathSeq;

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
    allocator: std.mem.Allocator,
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
            .allocator = allocator,
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
            @sizeOf(CommitSeq) * 1024 => self.pool512.destroy(@ptrCast(@alignCast(ptr))),
            else => self.allocator.free(ptr[0..len]),
        }
    }
};

pub const FixedBinaryAppendMergeOperaterState = struct {
    failed: [0]u8, // 当失败的时候返回其指针。
    mutex: std.Thread.Mutex,
    mempool_registry: std.ArrayList(*MemPool),
    allocator: std.mem.Allocator,
    pub fn init(allocator: std.mem.Allocator) FixedBinaryAppendMergeOperaterState {
        return .{
            .failed = .{},
            .mutex = .{},
            .mempool_registry = .empty,
            .allocator = allocator,
        };
    }
    pub fn deinit(self: *FixedBinaryAppendMergeOperaterState) void {
        for (self.mempool_registry.items) |threadlocal_mempool| {
            threadlocal_mempool.deinit();
            self.allocator.destroy(threadlocal_mempool);
        }
        self.mempool_registry.deinit(self.allocator);
    }
    fn reg(self: *FixedBinaryAppendMergeOperaterState) !void {
        std.debug.assert(local_mempool == null);
        local_mempool = try self.allocator.create(MemPool);
        local_mempool.?.* = .init(gvca.getAllocator());
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.mempool_registry.append(self.allocator, local_mempool.?);
    }
    pub fn createFixedBinaryAppendMergeOperater(self: *FixedBinaryAppendMergeOperaterState) *c.rocksdb_mergeoperator_t {
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
        const s: *FixedBinaryAppendMergeOperaterState = @ptrCast(@alignCast(state.?));
        if (local_mempool == null) s.reg() catch {
            std.log.err("mem pool reg failed!\n", .{});
        };
        _ = key;
        _ = key_length;
        const total_length = blk: {
            var tlen = if (existing_value != null) existing_value_length else 0;
            for (0..@intCast(num_operands)) |i| {
                tlen += operands_list_length[i];
            }
            break :blk tlen;
        };
        const result = local_mempool.?.create(total_length) catch {
            std.log.err("mem pool create failed! lotal length is {d}\n", .{total_length});
            success.* = 0;
            new_value_length.* = 0;
            // 注意到当内存不足的时候失败了还会无休止地反复调用，改换思路，快速失败。
            std.process.abort();
            // 分析C API源码发现merge失败时不会检查是否失败都会进行一次对`string`的赋值，如果返回`null`是未定义行为，于是借用state里的failed地址返回。
            return &s.failed;
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
        local_mempool.?.destroy(@constCast(value.?), value_length);
    }
    fn name(state: ?*anyopaque) callconv(.c) [*c]const u8 {
        _ = state;
        return "FixedBinaryAppendMergeOperater";
    }
};
