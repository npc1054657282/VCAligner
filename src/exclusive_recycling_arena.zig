// single-owner-at-a-time allocator

const std = @import("std");
const slab_len: usize = @max(std.heap.page_size_max, 64 * 1024);
/// Because of storing free list pointers, the minimum size class is 3.
const min_class = std.math.log2(@sizeOf(usize));
const size_class_count = std.math.log2(slab_len) - min_class;
fn sizeClassIndex(len: usize, alignment: std.mem.Alignment) usize {
    return @max(@bitSizeOf(usize) - @clz(len - 1), @intFromEnum(alignment), min_class) - min_class;
}
fn slotSize(class: usize) usize {
    return @as(usize, 1) << @intCast(class + min_class);
}
const slab_alignment = @as(std.mem.Alignment, @enumFromInt(std.math.log2(slab_len)));
// 一个SlabManager能装多少个子Slab指针
const max_manager_slabs = @divExact(slab_len - @sizeOf(?*anyopaque), @sizeOf([*]align(slab_alignment.toByteUnits()) u8));

const SlabManager = extern struct {
    next: ?*SlabManager,
    slabs: [max_manager_slabs][*]align(slab_alignment.toByteUnits()) u8,
};
const LargeObjectFooterNode = struct {
    prev: ?*LargeObjectFooterNode,
    next: ?*LargeObjectFooterNode,
    footer_offset: usize,
    alignment: std.mem.Alignment,
};
fn largeObjectActualAlignment(alignment: std.mem.Alignment) std.mem.Alignment {
    return @enumFromInt(@max(@intFromEnum(alignment), @intFromEnum(std.mem.Alignment.fromByteUnits(@alignOf(LargeObjectFooterNode)))));
}
pub fn ExclusiveRecyclingArena(comptime inline_slab_slot_count: comptime_int) type {
    return struct {
        pub const State = struct {
            next_addrs: [size_class_count]usize = @splat(0),
            frees: [size_class_count]usize = @splat(0),
            // 内联slab追踪管理，优先使用。
            inline_slab_slots: [inline_slab_slot_count][*]align(slab_alignment.toByteUnits()) u8 = undefined,
            // fallback slab管理员。内联slab管理耗尽时使用。
            head_slab_manager: ?*SlabManager = null,
            current_slab_manager: ?*SlabManager = null,
            allocated_slab_count: usize = 0,
            used_slab_count: usize = 0,
            // 大对象采用侵入式尾部链表记录。
            large_objects: ?*LargeObjectFooterNode = null,
            pub fn handle(self: *State, backing_allocator: std.mem.Allocator) Handle {
                return .{ .state = self, .backing_allocator = backing_allocator };
            }
        };
        pub const Handle = struct {
            state: *State,
            backing_allocator: std.mem.Allocator,
            pub fn allocator(self: *Handle) std.mem.Allocator {
                return .{
                    .ptr = self,
                    .vtable = &.{
                        .alloc = alloc,
                        .resize = resize,
                        .remap = remap,
                        .free = free,
                    },
                };
            }
            pub fn nominalAllocator(self: *Handle) NominalAllocator {
                return .{ .allocator = self.allocator() };
            }
            fn getOrAllocSlab(self: Handle) error{OutOfMemory}![*]align(slab_alignment.toByteUnits()) u8 {
                const idx = self.state.used_slab_count;
                // 内联Slab管理未用完
                if (idx < inline_slab_slot_count) {
                    if (idx < self.state.allocated_slab_count) {
                        self.state.used_slab_count += 1;
                        return self.state.inline_slab_slots[idx];
                    }
                    const new_slab_ptr = self.backing_allocator.rawAlloc(slab_len, slab_alignment, @returnAddress()) orelse return error.OutOfMemory;
                    errdefer comptime unreachable;
                    self.state.inline_slab_slots[idx] = @alignCast(new_slab_ptr);
                    self.state.allocated_slab_count += 1;
                    self.state.used_slab_count += 1;
                    return @alignCast(new_slab_ptr);
                }
                // fallback为使用Slab Manager
                const managed_slab_idx = idx - inline_slab_slot_count;
                const manager_idx = managed_slab_idx / max_manager_slabs;
                const slot_in_manager = managed_slab_idx % max_manager_slabs;

                if (idx < self.state.allocated_slab_count) {
                    // 需要翻页的情况：到达新manager的起点且不是第一个manager
                    if (slot_in_manager == 0 and manager_idx > 0) {
                        self.state.current_slab_manager = self.state.current_slab_manager.?.next;
                    }
                    const slab = self.state.current_slab_manager.?.slabs[slot_in_manager];
                    self.state.used_slab_count += 1;
                    return slab;
                }

                // 申请新Slab
                const new_slab_ptr = self.backing_allocator.rawAlloc(slab_len, slab_alignment, @returnAddress()) orelse return error.OutOfMemory;
                errdefer self.backing_allocator.rawFree(new_slab_ptr[0..slab_len], slab_alignment, @returnAddress());
                if (slot_in_manager == 0) {
                    const manager_slice_ptr = self.backing_allocator.rawAlloc(slab_len, slab_alignment, @returnAddress()) orelse return error.OutOfMemory;
                    errdefer comptime unreachable;
                    comptime std.debug.assert(@sizeOf(SlabManager) == slab_len);
                    comptime std.debug.assert(@alignOf(SlabManager) <= slab_alignment.toByteUnits());
                    const new_manager: *SlabManager = @ptrCast(@alignCast(manager_slice_ptr));
                    new_manager.next = null;

                    if (self.state.current_slab_manager) |curr| {
                        curr.next = new_manager;
                    } else {
                        self.state.head_slab_manager = new_manager;
                    }
                    self.state.current_slab_manager = new_manager;
                }
                self.state.current_slab_manager.?.slabs[slot_in_manager] = @alignCast(new_slab_ptr);

                self.state.allocated_slab_count += 1;
                self.state.used_slab_count += 1;
                return @alignCast(new_slab_ptr);
            }
            fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
                const self: *const Handle = @ptrCast(@alignCast(ctx));
                const class = sizeClassIndex(len, alignment);

                // 超大对象逃逸：采用侵入式尾部寄生设计
                if (class >= size_class_count) {
                    @branchHint(.unlikely);
                    // 尾部偏移计算
                    const footer_offset = std.mem.alignForward(usize, len, @alignOf(LargeObjectFooterNode));
                    const total_len = footer_offset + @sizeOf(LargeObjectFooterNode);
                    const actual_alignment = largeObjectActualAlignment(alignment);
                    const raw_ptr = self.backing_allocator.rawAlloc(total_len, actual_alignment, ra) orelse return null;
                    // 找到尾部，写入双向链表节点
                    const footer_ptr: *LargeObjectFooterNode = @ptrCast(@alignCast(raw_ptr + footer_offset));
                    // 头插法，挂入双向链表
                    footer_ptr.* = .{
                        .prev = null,
                        .next = self.state.large_objects,
                        .footer_offset = footer_offset,
                        .alignment = alignment,
                    };
                    if (self.state.large_objects) |head| head.prev = footer_ptr;
                    self.state.large_objects = footer_ptr;
                    return raw_ptr;
                }

                const slot_size = slotSize(class);

                // 查Free-list
                const top_free_ptr = self.state.frees[class];
                if (top_free_ptr != 0) {
                    @branchHint(.likely);
                    const node: *usize = @ptrFromInt(top_free_ptr);
                    self.state.frees[class] = node.*;
                    return @ptrFromInt(top_free_ptr);
                }

                // 查Bump游标
                const next_addr = self.state.next_addrs[class];
                if ((next_addr % slab_len) != 0) {
                    @branchHint(.likely);
                    self.state.next_addrs[class] = next_addr + slot_size;
                    return @ptrFromInt(next_addr);
                }

                // 获取Slab
                const slab_ptr = self.getOrAllocSlab() catch return null;

                self.state.next_addrs[class] = @intFromPtr(slab_ptr) + slot_size;
                return slab_ptr;
            }
            fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
                const self: *const Handle = @ptrCast(@alignCast(ctx));
                const class = sizeClassIndex(memory.len, alignment);

                // 超大分配
                if (class >= size_class_count) {
                    @branchHint(.unlikely);
                    // 推算出尾部偏移和节点地址
                    const footer_offset = std.mem.alignForward(usize, memory.len, @alignOf(LargeObjectFooterNode));
                    const footer_ptr: *LargeObjectFooterNode = @ptrCast(@alignCast(memory.ptr + footer_offset));
                    std.debug.assert(footer_ptr.footer_offset == footer_offset);
                    std.debug.assert(footer_ptr.alignment == alignment);
                    if (footer_ptr.prev) |p| p.next = footer_ptr.next else self.state.large_objects = footer_ptr.next;
                    if (footer_ptr.next) |n| n.prev = footer_ptr.prev;
                    // 重算总长度，还给操作系统
                    const total_len = footer_offset + @sizeOf(LargeObjectFooterNode);
                    const actual_alignment = largeObjectActualAlignment(alignment);
                    self.backing_allocator.rawFree(memory.ptr[0..total_len], actual_alignment, ra);
                    return;
                }

                // 小对象：直接挂入单向Free-list，绝不还给OS
                const node: *usize = @ptrCast(@alignCast(memory.ptr));
                node.* = self.state.frees[class];
                self.state.frees[class] = @intFromPtr(node);
            }
            fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
                const self: *const Handle = @ptrCast(@alignCast(ctx));
                const class = sizeClassIndex(memory.len, alignment);
                const new_class = sizeClassIndex(new_len, alignment);

                // 小对象/同档位逻辑
                if (class < size_class_count) {
                    return class == new_class;
                }

                // 超大对象跨档位缩小不允许原地缩，交由外部fallback
                if (new_class < size_class_count) return false;

                // 超大对象非跨档位
                const old_offset = std.mem.alignForward(usize, memory.len, @alignOf(LargeObjectFooterNode));
                const new_offset = std.mem.alignForward(usize, new_len, @alignOf(LargeObjectFooterNode));

                // 如果尾部偏移没变（如因内存对齐吃掉了差值），直接返回成功
                if (old_offset == new_offset) return true;

                const old_total = old_offset + @sizeOf(LargeObjectFooterNode);
                const new_total = new_offset + @sizeOf(LargeObjectFooterNode);
                // 备份原来的关系
                const prev, const next = blk: {
                    const old_footer: *LargeObjectFooterNode = @ptrCast(@alignCast(memory.ptr + old_offset));
                    std.debug.assert(old_footer.footer_offset == old_offset);
                    std.debug.assert(old_footer.alignment == alignment);
                    break :blk .{
                        old_footer.prev,
                        old_footer.next,
                    };
                };

                // 委托给底层进行原地缩放
                const actual_alignment = largeObjectActualAlignment(alignment);
                if (self.backing_allocator.rawResize(memory.ptr[0..old_total], actual_alignment, new_total, ra)) {

                    // 在新位置写入节点
                    const new_footer: *LargeObjectFooterNode = @ptrCast(@alignCast(memory.ptr + new_offset));
                    new_footer.* = .{
                        .prev = prev,
                        .next = next,
                        .footer_offset = new_offset,
                        .alignment = alignment,
                    };

                    // 更新邻居的指向
                    if (prev) |p| p.next = new_footer else self.state.large_objects = new_footer;
                    if (next) |n| n.prev = new_footer;

                    return true;
                }
                return false;
            }
            fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
                const self: *const Handle = @ptrCast(@alignCast(ctx));
                const class = sizeClassIndex(memory.len, alignment);
                const new_class = sizeClassIndex(new_len, alignment);

                // 小对象/同档位逻辑
                if (class < size_class_count) {
                    return if (class == new_class) memory.ptr else null;
                }

                // 超大对象如果变小回到了小对象范围，直接返回null让外部重分
                if (new_class < size_class_count) return null;

                // 超大对象非跨档位
                const old_offset = std.mem.alignForward(usize, memory.len, @alignOf(LargeObjectFooterNode));
                const new_offset = std.mem.alignForward(usize, new_len, @alignOf(LargeObjectFooterNode));

                const old_total = old_offset + @sizeOf(LargeObjectFooterNode);
                const new_total = new_offset + @sizeOf(LargeObjectFooterNode);
                // 备份原来的关系
                const prev, const next = blk: {
                    const old_footer: *LargeObjectFooterNode = @ptrCast(@alignCast(memory.ptr + old_offset));
                    std.debug.assert(old_footer.footer_offset == old_offset);
                    std.debug.assert(old_footer.alignment == alignment);
                    break :blk .{
                        old_footer.prev,
                        old_footer.next,
                    };
                };

                // 委托给底层remap
                const actual_alignment = largeObjectActualAlignment(alignment);
                if (self.backing_allocator.rawRemap(memory.ptr[0..old_total], actual_alignment, new_total, ra)) |new_ptr| {

                    // 在新地址的新尾部，重建节点
                    const new_footer: *LargeObjectFooterNode = @ptrCast(@alignCast(new_ptr + new_offset));
                    new_footer.* = .{
                        .prev = prev,
                        .next = next,
                        .footer_offset = new_offset,
                        .alignment = alignment,
                    };

                    // 修复链表关系，指向新地址
                    if (prev) |p| p.next = new_footer else self.state.large_objects = new_footer;
                    if (next) |n| n.prev = new_footer;

                    return new_ptr;
                }
                return null;
            }
            pub fn deinit(self: Handle) void {
                // 释放内联Slab
                const inline_count = @min(self.state.allocated_slab_count, inline_slab_slot_count);
                for (0..inline_count) |i| {
                    self.backing_allocator.rawFree(self.state.inline_slab_slots[i][0..slab_len], slab_alignment, @returnAddress());
                }
                // 释放管理员体系中的Slab及管理员自身
                var curr_manager = self.state.head_slab_manager;
                var manager_idx: usize = 0;
                while (curr_manager) |manager| {
                    const next_manager = manager.next;

                    const start_idx = inline_slab_slot_count + manager_idx * max_manager_slabs;
                    const end_idx = @min(self.state.allocated_slab_count, start_idx + max_manager_slabs);
                    const slabs_in_manager = end_idx - start_idx;

                    for (0..slabs_in_manager) |i| {
                        self.backing_allocator.rawFree(manager.slabs[i][0..slab_len], slab_alignment, @returnAddress());
                    }

                    // 销毁管理员自身
                    const manager_slice = @as([*]u8, @ptrCast(manager))[0..slab_len];
                    self.backing_allocator.rawFree(manager_slice, slab_alignment, @returnAddress());

                    curr_manager = next_manager;
                    manager_idx += 1;
                }
                // 释放大对象
                self.clearLarge();
            }
            pub fn reset(self: Handle) void {
                self.state.next_addrs = @splat(0);
                self.state.frees = @splat(0);
                self.state.used_slab_count = 0;
                self.state.current_slab_manager = self.state.head_slab_manager;

                // 大对象属于离群值，重置时一律清空归还OS
                self.clearLarge();
                self.state.large_objects = null;
            }
            fn clearLarge(self: Handle) void {
                var curr_large = self.state.large_objects;
                while (curr_large) |node| {
                    curr_large = node.next;
                    const total_len = node.footer_offset + @sizeOf(LargeObjectFooterNode);
                    const original_addr = @as([*]u8, @ptrCast(node)) - node.footer_offset;
                    const raw_slice = original_addr[0..total_len];
                    const alignment = largeObjectActualAlignment(node.alignment);
                    self.backing_allocator.rawFree(raw_slice, alignment, @returnAddress());
                }
            }
        };
    };
}

// 这是为了在类型系统中区分本分配器与其它std.mem.Allocator的名义包装
pub const NominalAllocator = struct {
    allocator: std.mem.Allocator,
};

test "reset with preheating" {
    var arena_state: ExclusiveRecyclingArena(16).State = .{};
    var arena_allocator = arena_state.handle(std.testing.allocator);
    defer arena_allocator.deinit();
    // provides some variance in the allocated data
    var rng_src = std.Random.DefaultPrng.init(std.testing.random_seed);
    const random = rng_src.random();
    var rounds: usize = 25;
    while (rounds > 0) {
        rounds -= 1;
        _ = arena_allocator.reset();
        var alloced_bytes: usize = 0;
        const total_size: usize = random.intRangeAtMost(usize, 256, 16384);
        while (alloced_bytes < total_size) {
            const size = random.intRangeAtMost(usize, 16, 256);
            const alignment: std.mem.Alignment = .@"32";
            const slice = try arena_allocator.allocator().alignedAlloc(u8, alignment, size);
            try std.testing.expect(alignment.check(@intFromPtr(slice.ptr)));
            try std.testing.expectEqual(size, slice.len);
            alloced_bytes += slice.len;
        }
    }
}

test "small object free-list reuse" {
    var state: ExclusiveRecyclingArena(0).State = .{};
    var handle = state.handle(std.testing.allocator);
    defer handle.deinit();

    const gpa = handle.allocator();

    // 分配同一size class的多个对象
    const a = try gpa.alloc(u8, 32);
    const b = try gpa.alloc(u8, 32);
    const c = try gpa.alloc(u8, 32);

    // 释放后应能复用
    gpa.free(b);
    const d = try gpa.alloc(u8, 32);
    // d就是刚才释放的b（地址相同）
    try std.testing.expect(d.ptr == b.ptr);

    gpa.free(a);
    gpa.free(c);
    gpa.free(d);
}

test "different size classes do not interfere" {
    var state: ExclusiveRecyclingArena(0).State = .{};
    var handle = state.handle(std.testing.allocator);
    defer handle.deinit();

    const gpa = handle.allocator();

    const small = try gpa.alloc(u8, 16);
    const medium = try gpa.alloc(u8, 64);
    const large_small = try gpa.alloc(u8, 256);

    gpa.free(medium);
    // 释放medium不应影响其它class
    const medium2 = try gpa.alloc(u8, 64);
    try std.testing.expect(medium2.ptr == medium.ptr);

    gpa.free(small);
    gpa.free(large_small);
    gpa.free(medium2);
}

test "large object basic lifecycle" {
    var state: ExclusiveRecyclingArena(0).State = .{};
    var handle = state.handle(std.testing.allocator);
    defer handle.deinit();

    const gpa = handle.allocator();

    // 强制走大对象路径（超过slab_len）
    const big_len = slab_len + 1024;
    const big = try gpa.alloc(u8, big_len);
    try std.testing.expect(big.len == big_len);

    // 写入一点数据验证可访问
    @memset(big, 0xAB);

    gpa.free(big);

    // 再次分配应成功（可能拿到新地址）
    const big2 = try gpa.alloc(u8, big_len);
    gpa.free(big2);
}

test "large object with weak alignment" {
    var state: ExclusiveRecyclingArena(0).State = .{};
    var handle = state.handle(std.testing.allocator);
    defer handle.deinit();

    const gpa = handle.allocator();

    // 用户只要求很弱的对齐，测试largeObjectActualAlignment是否生效
    const weak_align: std.mem.Alignment = .@"1";
    const big_len = slab_len + 512;

    const ptr = try gpa.alignedAlloc(u8, weak_align, big_len);
    defer gpa.free(ptr);

    // 返回的指针必须满足用户请求的对齐
    try std.testing.expect(weak_align.check(@intFromPtr(ptr.ptr)));
    // 同时也应满足footer的对齐要求
    try std.testing.expect(std.mem.Alignment.fromByteUnits(@alignOf(LargeObjectFooterNode)).check(@intFromPtr(ptr.ptr)));
}

test "reset clears free lists and large objects but keeps slabs" {
    var state: ExclusiveRecyclingArena(1).State = .{};
    var handle = state.handle(std.testing.allocator);
    defer handle.deinit();

    const gpa = handle.allocator();

    // 分配并释放一些小对象+一个大对象
    const a = try gpa.alloc(u8, 64);
    const b = try gpa.alloc(u8, 64);
    gpa.free(a);
    gpa.free(b);

    const big = try gpa.alloc(u8, slab_len + 128);
    _ = big;
    // 不free，留给reset清理

    const allocated_before = state.allocated_slab_count;
    try std.testing.expect(allocated_before > 0);

    handle.reset();

    // free-list应被清空
    for (state.frees) |f| try std.testing.expect(f == 0);
    // used_slab_count归零
    try std.testing.expect(state.used_slab_count == 0);
    // 大对象应被真正释放
    try std.testing.expect(state.large_objects == null);
    // 已分配的slab数量应保持
    try std.testing.expect(state.allocated_slab_count == allocated_before);

    // 再次分配应能复用已有slab
    const c = try gpa.alloc(u8, 64);
    try std.testing.expect(state.used_slab_count >= 1);
    gpa.free(c);
}

test "deinit frees all memory" {
    var state: ExclusiveRecyclingArena(1).State = .{};
    var handle = state.handle(std.testing.allocator);
    // 这里不用defer deinit，手动调用以便观察

    const gpa = handle.allocator();

    _ = try gpa.alloc(u8, 32);
    _ = try gpa.alloc(u8, 128);
    _ = try gpa.alloc(u8, slab_len + 64); // 大对象

    // 此时有inline/managed slab+大对象
    try std.testing.expect(state.allocated_slab_count > 0);
    try std.testing.expect(state.large_objects != null);

    handle.deinit();

    // deinit 后状态应被清理
    // 这里主要依赖testing.allocator的leak 检测
}

test "resize small object" {
    var state: ExclusiveRecyclingArena(0).State = .{};
    var handle = state.handle(std.testing.allocator);
    defer handle.deinit();

    const gpa = handle.allocator();

    var buf = try gpa.alloc(u8, 32);
    // 同class内缩小/扩大应成功
    try std.testing.expect(gpa.resize(buf, 24));
    buf = buf.ptr[0..24];

    try std.testing.expect(!gpa.resize(buf, 40));
}

test "resize large object" {
    var state: ExclusiveRecyclingArena(0).State = .{};
    var handle = state.handle(std.testing.allocator);
    defer handle.deinit();

    const gpa = handle.allocator();

    const orig_len = slab_len + 256;
    var buf = try gpa.alloc(u8, orig_len);
    @memset(buf, 0xCD);

    // 同档位缩小
    const new_len = orig_len - 64;
    if (gpa.resize(buf, new_len)) {
        buf = buf.ptr[0..new_len];
        // 数据前缀应保持
        try std.testing.expect(buf[0] == 0xCD);
    }

    // 尝试扩大（底层可能支持也可能不支持）
    if (gpa.resize(buf, orig_len + 128)) {
        buf = buf.ptr[0 .. orig_len + 128];
    }
    gpa.free(buf);
}

test "remap large object may move" {
    var state: ExclusiveRecyclingArena(0).State = .{};
    var handle = state.handle(std.testing.allocator);
    defer handle.deinit();

    const gpa = handle.allocator();

    const orig_len = slab_len + 128;
    const buf = try gpa.alloc(u8, orig_len);
    @memset(buf, 0xEF);

    // remap到更大尺寸
    if (gpa.remap(buf, orig_len + 512)) |new_buf| {
        // 如果地址变了，数据应被正确拷贝
        try std.testing.expect(new_buf[0] == 0xEF);
        gpa.free(new_buf);
    } else {
        // 底层不支持remap，回退到手动处理
        gpa.free(buf);
    }
}

test "mixed small and large with multiple resets" {
    var state: ExclusiveRecyclingArena(16).State = .{};
    var handle = state.handle(std.testing.allocator);
    defer handle.deinit();

    const gpa = handle.allocator();
    var rng = std.Random.DefaultPrng.init(0x12345678);
    const random = rng.random();

    var round: usize = 0;
    while (round < 10) : (round += 1) {
        handle.reset();

        var pending8: std.ArrayListUnmanaged([]align(8) u8) = .empty;
        defer {
            for (pending8.items) |s| gpa.free(s);
            pending8.deinit(gpa);
        }

        var pending32: std.ArrayListUnmanaged([]align(32) u8) = .empty;
        defer {
            for (pending32.items) |s| gpa.free(s);
            pending32.deinit(gpa);
        }

        var allocated: usize = 0;
        const target = random.intRangeAtMost(usize, 1024, 32 * 1024);

        while (allocated < target) {
            const size = random.intRangeAtMost(usize, 8, slab_len + 2048);

            if (random.boolean()) {
                // 8字节对齐路径
                const slice = try gpa.alignedAlloc(u8, .@"8", size);
                try std.testing.expect(std.mem.Alignment.@"8".check(@intFromPtr(slice.ptr)));
                @memset(slice, @truncate(round));

                if (random.boolean() and slice.len < slab_len) {
                    // 立即释放，制造free-list
                    gpa.free(slice);
                } else {
                    // 延迟释放
                    try pending8.append(gpa, slice);
                    allocated += slice.len;
                }
            } else {
                // 32字节对齐路径
                const slice = try gpa.alignedAlloc(u8, .@"32", size);
                try std.testing.expect(std.mem.Alignment.@"32".check(@intFromPtr(slice.ptr)));
                @memset(slice, @truncate(round));

                if (random.boolean() and slice.len < slab_len) {
                    // 立即释放，制造free-list
                    gpa.free(slice);
                } else {
                    // 延迟释放
                    try pending32.append(gpa, slice);
                    allocated += slice.len;
                }
            }
        }

        // 本轮结束前也可以选择提前释放一部分延迟对象，增加路径覆盖
        if (random.boolean() and pending8.items.len > 0) {
            const idx = random.intRangeLessThan(usize, 0, pending8.items.len);
            gpa.free(pending8.swapRemove(idx));
        }
        if (random.boolean() and pending32.items.len > 0) {
            const idx = random.intRangeLessThan(usize, 0, pending32.items.len);
            gpa.free(pending32.swapRemove(idx));
        }
    }
}

test "alignment is respected for small objects" {
    var state: ExclusiveRecyclingArena(0).State = .{};
    var handle = state.handle(std.testing.allocator);
    defer handle.deinit();

    const gpa = handle.allocator();

    const alignments = [_]std.mem.Alignment{ .@"1", .@"2", .@"4", .@"8", .@"16", .@"32", .@"64" };

    inline for (alignments) |alignment| {
        const size = 48; // 选一个不是2的幂的大小
        const slice = try gpa.alignedAlloc(u8, alignment, size);
        try std.testing.expect(alignment.check(@intFromPtr(slice.ptr)));
        try std.testing.expect(slice.len == size);
        gpa.free(slice);
    }
}

test "zero size and minimum size" {
    var state: ExclusiveRecyclingArena(0).State = .{};
    var handle = state.handle(std.testing.allocator);
    defer handle.deinit();

    const gpa = handle.allocator();

    const empty = try gpa.alloc(u8, 0);
    gpa.free(empty);

    // 最小有意义的小对象
    const min = try gpa.alloc(u8, 1);
    try std.testing.expect(min.len == 1);
    gpa.free(min);
}
