const std = @import("std");
const vcaligner = @import("vcaligner");
const analysis = @import("analysis.zig");
fn numMasks(bit_length: usize) usize {
    return (bit_length + (@bitSizeOf(std.DynamicBitSetUnmanaged.MaskInt) - 1)) / @bitSizeOf(std.DynamicBitSetUnmanaged.MaskInt);
}

pub const EventNode = struct {
    time: vcaligner.rocksdb_custom.CommitSeqNative,
    evidence_idx: u32,
    pub fn compare(context: void, a: EventNode, b: EventNode) std.math.Order {
        _ = context;
        return std.math.order(a.time, b.time);
    }
};
pub fn analyseCandidatesHeapSweep(
    evidences: []const analysis.AgendaUnit,
    gpa: vcaligner.gpa.Exclusive,
) !Candidate.Set {
    var cache: Cache = .{
        .map = .empty,
        .maximals = .empty,
        .cells_depot = .init(gpa.allocator),
    };
    errdefer cache.deinit(gpa.allocator);
    const cursors = try gpa.allocator.alloc(usize, evidences.len);
    @memset(cursors, 0);
    defer gpa.allocator.free(cursors);
    var active_evidences: std.DynamicBitSetUnmanaged = try .initEmpty(gpa.allocator, evidences.len);
    // 缓存evidence数量，避免动态bitset每次执行`active_evidences.count()`时重复扫描的开销。
    var active_evidences_count: u32 = 0;
    defer active_evidences.deinit(gpa.allocator);
    var pq: vcaligner.PriorityQueue(EventNode, void, EventNode.compare) = blk: {
        const init_events: []EventNode = try gpa.allocator.alloc(EventNode, evidences.len);
        errdefer comptime unreachable;
        for (evidences, init_events, 0..) |*evidence, *event_node, r| {
            std.debug.assert(evidence.commit_collection.ranges.len > 0);
            event_node.* = .{
                .time = evidence.commit_collection.ranges[0].start,
                .evidence_idx = @intCast(r),
            };
        }
        break :blk .fromOwnedSlice(init_events, {});
    };
    defer pq.deinit(gpa.allocator);
    std.debug.assert(pq.cap >= evidences.len);
    var current_time: vcaligner.rocksdb_custom.CommitSeqNative = 0;
    while (pq.peek()) |first_event| {
        const min_event_time = first_event.time;
        if (active_evidences_count > 0 and current_time < min_event_time) {
            const valid_range: vcaligner.commit_range.CommitRange = .packStartEnd(current_time, min_event_time - 1);
            try commitToCache(gpa.allocator, &cache, &active_evidences, valid_range);
        }
        continuous_replace: while (pq.peek()) |event| {
            if (event.time != min_event_time) break :continuous_replace;
            const r = event.evidence_idx;
            const commit_collection = evidences[r].commit_collection;
            active_evidences.toggle(r);
            const new_event: ?EventNode = blk: {
                if (active_evidences.isSet(r)) {
                    active_evidences_count += 1;
                    const end_time = commit_collection.ranges[cursors[r]].end;
                    const time = std.math.add(end_time, 1) catch break :blk null;
                    break :blk .{ .time = time, .evidence_idx = r };
                }
                active_evidences_count -= 1;
                cursors[r] += 1;
                if (cursors[r] >= commit_collection.ranges.len) {
                    break :blk null;
                }
                break :blk .{
                    .time = commit_collection.ranges[cursors[r]].start,
                    .evidence_idx = r,
                };
            };
            if (new_event) |replace| {
                // 新加入的event有这样的特征，必定不小于被pop掉的event。
                // 所以可以替换原位置后sift down而非先pop再push。
                pq.items[0] = replace;
                pq.siftDown(0);
            } else _ = pq.popIndex(0);
        }
        current_time = min_event_time;
    }
    if (active_evidences_count > 0) {
        const max_time = std.math.maxInt(vcaligner.rocksdb_custom.CommitSeqNative);
        const valid_range: vcaligner.commit_range.CommitRange = .packStartEnd(current_time, max_time);
        try commitToCache(gpa.allocator, &cache, &active_evidences, valid_range);
    }
    return try cache.toOwnedCandidateSet(gpa.allocator, evidences.len);
}

pub fn analyseCandidatesSweep(
    evidences: []const analysis.AgendaUnit,
    gpa: vcaligner.gpa.Exclusive,
) !Candidate.Set {
    var cache: Cache = .{
        .map = .empty,
        .maximals = .empty,
        .cells_depot = .init(gpa.allocator),
    };
    errdefer cache.deinit(gpa.allocator);
    const cursors = try gpa.allocator.alloc(usize, evidences.len);
    @memset(cursors, 0);
    defer gpa.allocator.free(cursors);
    var active_evidences: std.DynamicBitSetUnmanaged = try .initEmpty(gpa.allocator, evidences.len);
    defer active_evidences.deinit(gpa.allocator);
    var evidences_triggering_at_min: std.DynamicBitSetUnmanaged = try .initEmpty(gpa.allocator, evidences.len);
    defer evidences_triggering_at_min.deinit(gpa.allocator);
    var current_time: vcaligner.rocksdb_custom.CommitSeqNative = 0;
    while (true) {
        var maybe_min_event_time: ?vcaligner.rocksdb_custom.CommitSeqNative = null;
        scan_min_event_time: for (evidences, 0..) |*evidence, r| {
            const commit_collection = evidence.commit_collection;
            if (cursors[r] >= commit_collection.ranges.len) continue :scan_min_event_time;
            const range = commit_collection.ranges[cursors[r]];
            const event_time = if (active_evidences.isSet(r)) std.math.add(range.end, 1) catch continue :scan_min_event_time else range.start;
            reset_old_state: {
                if (maybe_min_event_time) |min_event_time| {
                    if (event_time > min_event_time) continue :scan_min_event_time;
                    if (event_time == min_event_time) break :reset_old_state;
                }
                maybe_min_event_time = event_time;
                evidences_triggering_at_min.unsetAll();
            }
            evidences_triggering_at_min.set(r);
        }
        if (maybe_min_event_time) |min_event_time| {
            if (active_evidences.count() > 0 and current_time < min_event_time) {
                const valid_range: vcaligner.commit_range.CommitRange = .packStartEnd(current_time, min_event_time - 1);
                try commitToCache(gpa.allocator, &cache, &active_evidences, valid_range);
            }
            // 状态推进
            var it = evidences_triggering_at_min.iterator(.{});
            while (it.next()) |r| {
                active_evidences.toggle(r);
                if (!active_evidences.isSet(r)) {
                    cursors[r] += 1;
                }
            }
            current_time = min_event_time;
        } else break;
    }
    if (active_evidences.count() > 0) {
        const max_time = std.math.maxInt(vcaligner.rocksdb_custom.CommitSeqNative);
        const valid_range: vcaligner.commit_range.CommitRange = .packStartEnd(current_time, max_time);
        try commitToCache(gpa.allocator, &cache, &active_evidences, valid_range);
    }
    return try cache.toOwnedCandidateSet(gpa.allocator, evidences.len);
}

fn commitToCache(
    allocator: std.mem.Allocator,
    cache: *Cache,
    evidences: *const std.DynamicBitSetUnmanaged,
    valid_range: vcaligner.commit_range.CommitRange,
) !void {
    const hash_context: Signature.Context = .{ .bit_length = evidences.bit_length };
    if (cache.map.getKeyContext(.{ .raw = evidences.masks }, hash_context)) |signature| {
        const cell: Cache.Cell = .fromSignature(signature);
        switch (cell.heap_ptr.*) {
            .maximal => |maximal_id| {
                try cache.maximals.items[maximal_id].commit_collection.appendRangeAssumeGreater(allocator, valid_range);
            },
            .dominated => {},
        }
        return;
    }
    try cache.map.ensureUnusedCapacityContext(allocator, 1, hash_context);
    try cache.maximals.ensureUnusedCapacity(allocator, 1);
    const cell: Cache.Cell = try .initUndefined(cache.cells_depot.allocator(), evidences.bit_length);
    @memcpy(cell.heap_ptr.signature().raw, evidences.masks[0..numMasks(evidences.bit_length)]);
    errdefer cell.deinit(cache.cells_depot.allocator(), evidences.bit_length);
    var current_maximal_index: usize = 0;
    dominated: {
        var commit_collection: vcaligner.commit_range.CommitCollection.Builder = .init;
        errdefer commit_collection.b.deinit(allocator);
        maximal: while (true) {
            if (current_maximal_index == cache.maximals.items.len) break :maximal;
            const current_signature_bit_set = cache.maximals.items[current_maximal_index].cell.heap_ptr.signature().promote(evidences.bit_length);
            if (current_signature_bit_set.supersetOf(evidences)) {
                cell.heap_ptr.* = .dominated;
                commit_collection.b.deinit(allocator);
                break :dominated;
            }
            if (current_signature_bit_set.subsetOf(evidences)) {
                if (commit_collection.b.items.len == 0)
                    try commit_collection.appendRangeAssumeGreater(allocator, valid_range);
                const removed = cache.maximals.swapRemove(current_maximal_index);
                removed.cell.heap_ptr.* = .dominated;
                removed.commit_collection.b.deinit(allocator);
                if (current_maximal_index < cache.maximals.items.len) {
                    cache.maximals.items[current_maximal_index].cell.heap_ptr.maximal = current_maximal_index;
                }
                continue :maximal;
            }
            current_maximal_index += 1;
        }
        if (commit_collection.b.items.len == 0)
            try commit_collection.appendRangeAssumeGreater(allocator, valid_range);
        cell.heap_ptr.* = .{ .maximal = cache.maximals.items.len };
        cache.maximals.appendAssumeCapacity(.{
            .commit_collection = commit_collection,
            .cell = cell,
        });
    }
    cache.map.putAssumeCapacityNoClobberContext(cell.heap_ptr.signature(), {}, hash_context);
}

pub const Cache = struct {
    map: std.HashMapUnmanaged(Signature, void, Signature.Context, std.hash_map.default_max_load_percentage),
    maximals: std.ArrayListUnmanaged(Maximal),
    cells_depot: vcaligner.StArena,
    pub fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        for (self.maximals.items) |*maximal| {
            maximal.commit_collection.b.deinit(allocator);
        }
        self.maximals.deinit(allocator);
        self.map.deinit(allocator);
        self.cells_depot.deinit();
    }
    pub fn toOwnedCandidateSet(self: *Cache, allocator: std.mem.Allocator, bit_length: usize) !Candidate.Set {
        var candidates: std.ArrayListUnmanaged(Candidate) = try .initCapacity(allocator, self.maximals.items.len);
        errdefer {
            for (candidates.items, self.maximals.items[0..candidates.items.len]) |*candidate, *maximal| {
                maximal.commit_collection.b = .fromOwnedSlice(candidate.commits.ranges);
                var bit_set = candidate.signature.promote(bit_length);
                bit_set.deinit(allocator);
            }
            candidates.deinit(allocator);
        }
        for (self.maximals.items) |*maximal| {
            const commits = try maximal.commit_collection.toOwnedCommitRanges(allocator);
            errdefer maximal.commit_collection.b = .fromOwnedSlice(commits.ranges);
            var sig_bit_map = maximal.cell.heap_ptr.signature().promote(bit_length);
            const signature = .{ .raw = (try sig_bit_map.clone(allocator)).masks };
            candidates.appendAssumeCapacity(.{
                .commits = commits,
                .signature = signature,
            });
        }
        const set: Candidate.Set = .{ .candidates = try candidates.toOwnedSlice(allocator) };
        self.maximals.clearRetainingCapacity();
        self.deinit(allocator);
        return set;
    }
    pub const Cell = struct {
        pub const signature_offset = std.mem.alignForward(usize, @sizeOf(Header), @alignOf(std.DynamicBitSetUnmanaged.MaskInt));
        pub const Header = union(enum) {
            maximal: usize,
            dominated: void,
            pub inline fn signature(self: *Header) Signature {
                // see https://codeberg.org/ziglang/zig/pulls/30823#issuecomment-9818066
                return .{ .raw = @ptrCast(@alignCast(@as([*]u8, @ptrCast(self)) + signature_offset)) };
            }
        };
        pub const heap_align: std.mem.Alignment = .max(.of(Header), .of(std.DynamicBitSetUnmanaged.MaskInt));
        heap_ptr: *align(heap_align.toByteUnits()) Header,
        pub fn heapSize(bit_length: usize) usize {
            return signature_offset + (@sizeOf(std.DynamicBitSetUnmanaged.MaskInt) * numMasks(bit_length));
        }
        pub fn initUndefined(allocator: std.mem.Allocator, bit_length: usize) !@This() {
            const raw = try allocator.alignedAlloc(u8, heap_align, heapSize(bit_length));
            errdefer comptime unreachable;
            const heap_ptr: *align(heap_align.toByteUnits()) Header = @ptrCast(raw);
            return .{ .heap_ptr = heap_ptr };
        }
        pub fn deinit(self: Cell, allocator: std.mem.Allocator, bit_length: usize) void {
            const raw = @as([*]align(heap_align.toByteUnits()) u8, @ptrCast(self.heap_ptr))[0..heapSize(bit_length)];
            allocator.free(raw);
        }
        pub fn fromSignature(signature: Signature) Cell {
            return .{ .heap_ptr = @ptrCast(@alignCast(@as([*]u8, @ptrCast(signature.raw)) - signature_offset)) };
        }
    };
    pub const Maximal = struct {
        cell: Cell,
        commit_collection: vcaligner.commit_range.CommitCollection.Builder,
    };
};

pub const Signature = struct {
    raw: [*]std.DynamicBitSetUnmanaged.MaskInt,
    pub fn promote(self: Signature, bit_length: usize) std.DynamicBitSetUnmanaged {
        return .{
            .bit_length = bit_length,
            .masks = self.raw,
        };
    }
    pub const Context = struct {
        bit_length: usize,
        pub fn hash(self: Context, c: Signature) u64 {
            const masks = c.raw[0..numMasks(self.bit_length)];
            var hasher = std.hash.Wyhash.init(0);
            std.hash.autoHashStrat(&hasher, masks, .Deep);
            return hasher.final();
        }
        pub fn eql(self: Context, a: Signature, b: Signature) bool {
            return a.promote(self.bit_length).eql(b.promote(self.bit_length));
        }
    };
};
pub const Candidate = struct {
    commits: vcaligner.commit_range.CommitCollection,
    signature: Signature,
    pub fn deinit(self: Candidate, allocator: std.mem.Allocator, bit_length: usize) void {
        self.commits.deinit(allocator);
        var bit_set = self.signature.promote(bit_length);
        bit_set.deinit(allocator);
    }
    pub const Set = struct {
        candidates: []Candidate,
        pub fn deinit(self: Set, allocator: std.mem.Allocator, bit_length: usize) void {
            for (self.candidates) |*candidate| {
                candidate.deinit(allocator, bit_length);
            }
            allocator.free(self.candidates);
        }
    };
};
