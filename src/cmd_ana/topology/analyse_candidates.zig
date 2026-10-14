const std = @import("std");
const vcaligner = @import("vcaligner");
const analysis = @import("analysis.zig");
fn numMasks(bit_length: usize) usize {
    return (bit_length + (@bitSizeOf(std.DynamicBitSetUnmanaged.MaskInt) - 1)) / @bitSizeOf(std.DynamicBitSetUnmanaged.MaskInt);
}

// 比较两个完整signature的判别性前缀。
// non-discriminative evidences按EvidenceStrength排序后位于该前缀之后，
// 因而无需构造第二份bitset，也无需在dominance时分配临时内存。
fn bitSetPrefixSubsetOf(
    lhs: [*]const std.DynamicBitSetUnmanaged.MaskInt,
    rhs: [*]const std.DynamicBitSetUnmanaged.MaskInt,
    bit_length: u32,
) bool {
    const bit_length_usize: usize = @intCast(bit_length);
    const MaskInt = std.DynamicBitSetUnmanaged.MaskInt;
    const mask_bit_length = @bitSizeOf(MaskInt);
    const whole_masks = bit_length_usize / mask_bit_length;
    for (0..whole_masks) |i| {
        if ((lhs[i] & ~rhs[i]) != 0) return false;
    }
    const remaining_bits = bit_length_usize % mask_bit_length;
    if (remaining_bits == 0) return true;
    const ShiftInt = std.math.Log2Int(MaskInt);
    const valid_mask = (@as(MaskInt, 1) << @as(ShiftInt, @intCast(remaining_bits))) - 1;
    return ((lhs[whole_masks] & ~rhs[whole_masks]) & valid_mask) == 0;
}

fn bitSetPrefixSupersetOf(
    lhs: [*]const std.DynamicBitSetUnmanaged.MaskInt,
    rhs: [*]const std.DynamicBitSetUnmanaged.MaskInt,
    bit_length: u32,
) bool {
    return bitSetPrefixSubsetOf(rhs, lhs, bit_length);
}

pub const EventNode = struct {
    time: vcaligner.rocksdb_custom.CommitSeqNative,
    evidence_idx: u32,
    pub fn compare(context: void, a: EventNode, b: EventNode) std.math.Order {
        _ = context;
        return std.math.order(a.time, b.time);
    }
};
pub fn analyseCandidates(
    evidences: []const analysis.Evidences.Unit,
    discriminative_evidence_count: u32,
    gpa: vcaligner.gpa.Exclusive,
    seed: u64,
) !Candidate.Set {
    std.debug.assert(evidences.len <= std.math.maxInt(u32));
    std.debug.assert(discriminative_evidence_count <= @as(u32, @intCast(evidences.len)));
    var cache: Cache = .{
        .map = .empty,
        .maximals = .empty,
        .cells_depot = .init(gpa.allocator),
    };
    errdefer cache.deinit(gpa.allocator);
    const cursors = try gpa.allocator.alloc(usize, evidences.len);
    @memset(cursors, 0);
    defer gpa.allocator.free(cursors);
    const zobrist_table = blk: {
        const zobrist_table = try gpa.allocator.alloc(u64, evidences.len);
        errdefer comptime unreachable;
        var prng = std.Random.DefaultPrng.init(seed);
        for (zobrist_table) |*r| {
            r.* = prng.random().int(u64);
        }
        break :blk zobrist_table;
    };
    defer gpa.allocator.free(zobrist_table);
    var active_evidences: Cache.PseudoKey = .{
        .bit_set = try .initEmpty(gpa.allocator, evidences.len),
        .hash = 0,
    };
    defer active_evidences.bit_set.deinit(gpa.allocator);
    // 两个count均为缓存值，避免反复扫描动态bitset。
    // dominance只使用discriminative count；total count保留用于完整signature排序。
    var active_total_evidence_count: u32 = 0;
    var active_discriminative_evidence_count: u32 = 0;

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
        if (active_total_evidence_count > 0 and current_time < min_event_time) {
            const valid_range: vcaligner.commit_range.CommitRange = .packStartEnd(current_time, min_event_time - 1);
            try commitToCache(
                gpa.allocator,
                &cache,
                &active_evidences,
                active_total_evidence_count,
                active_discriminative_evidence_count,
                discriminative_evidence_count,
                valid_range,
            );
        }
        continuous_replace: while (pq.peek()) |event| {
            if (event.time != min_event_time) break :continuous_replace;
            const r = event.evidence_idx;
            const commit_collection = evidences[r].commit_collection;
            const is_discriminative = r < discriminative_evidence_count;
            active_evidences.bit_set.toggle(r);
            active_evidences.hash ^= zobrist_table[r];
            const new_event: ?EventNode = blk: {
                if (active_evidences.bit_set.isSet(r)) {
                    active_total_evidence_count += 1;
                    if (is_discriminative) active_discriminative_evidence_count += 1;
                    const end_time = commit_collection.ranges[cursors[r]].end;
                    const time = std.math.add(u32, end_time, 1) catch break :blk null;
                    break :blk .{ .time = time, .evidence_idx = r };
                }
                active_total_evidence_count -= 1;
                if (is_discriminative) active_discriminative_evidence_count -= 1;
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
    if (active_total_evidence_count > 0) {
        const max_time = std.math.maxInt(vcaligner.rocksdb_custom.CommitSeqNative);
        const valid_range: vcaligner.commit_range.CommitRange = .packStartEnd(current_time, max_time);
        try commitToCache(
            gpa.allocator,
            &cache,
            &active_evidences,
            active_total_evidence_count,
            active_discriminative_evidence_count,
            discriminative_evidence_count,
            valid_range,
        );
    }
    return try cache.toOwnedCandidateSet(gpa.allocator, evidences.len);
}

fn commitToCache(
    allocator: std.mem.Allocator,
    cache: *Cache,
    evidences: *const Cache.PseudoKey,
    total_evidence_count: u32,
    discriminative_evidence_count: u32,
    discriminative_bit_length: u32,
    valid_range: vcaligner.commit_range.CommitRange,
) !void {
    const pseudo_context: Cache.PseudoKey.Context = .{};
    if (cache.map.getKeyAdapted(evidences.*, pseudo_context)) |signature| {
        const cell: Cache.Cell = .fromSignature(signature);
        switch (cell.heap_ptr.state) {
            .maximal => |maximal_info| {
                try cache.maximals.items[maximal_info.slot_idx].commit_collection.appendRangeAssumeGreater(allocator, valid_range);
            },
            .dominated => {},
        }
        return;
    }
    const hash_context: Cache.MapContext = .{ .bit_length = evidences.bit_set.bit_length };
    try cache.map.ensureUnusedCapacityContext(allocator, 1, hash_context);
    try cache.maximals.ensureUnusedCapacity(allocator, 1);
    const cell: Cache.Cell = try .initUndefined(cache.cells_depot.allocator(), evidences.bit_set.bit_length);
    @memcpy(cell.heap_ptr.signature().raw, evidences.bit_set.masks[0..numMasks(evidences.bit_set.bit_length)]);
    errdefer cell.deinit(cache.cells_depot.allocator(), evidences.bit_set.bit_length);
    var current_maximal_index: usize = 0;
    dominated: {
        var commit_collection: vcaligner.commit_range.CommitCollection.Builder = .init;
        errdefer commit_collection.b.deinit(allocator);
        maximal: while (true) {
            if (current_maximal_index == cache.maximals.items.len) break :maximal;
            const current_cell = cache.maximals.items[current_maximal_index].cell;
            const current_discriminative_evidence_count = current_cell.heap_ptr.state.maximal.discriminative_evidence_count;
            switch (std.math.order(current_discriminative_evidence_count, discriminative_evidence_count)) {
                .gt => {
                    if (bitSetPrefixSupersetOf(
                        current_cell.heap_ptr.signature().raw,
                        evidences.bit_set.masks,
                        discriminative_bit_length,
                    )) {
                        cell.heap_ptr.* = .{
                            .state = .dominated,
                            .hash = evidences.hash,
                        };
                        commit_collection.b.deinit(allocator);
                        break :dominated;
                    }
                },
                .lt => {
                    if (bitSetPrefixSubsetOf(
                        current_cell.heap_ptr.signature().raw,
                        evidences.bit_set.masks,
                        discriminative_bit_length,
                    )) {
                        if (commit_collection.b.items.len == 0)
                            try commit_collection.appendRangeAssumeGreater(allocator, valid_range);
                        var removed = cache.maximals.swapRemove(current_maximal_index);
                        removed.cell.heap_ptr.state = .dominated;
                        removed.commit_collection.b.deinit(allocator);
                        if (current_maximal_index < cache.maximals.items.len) {
                            cache.maximals.items[current_maximal_index].cell.heap_ptr.state.maximal.slot_idx = @intCast(current_maximal_index);
                        }
                        continue :maximal;
                    }
                },
                .eq => {},
            }
            current_maximal_index += 1;
        }
        if (commit_collection.b.items.len == 0)
            try commit_collection.appendRangeAssumeGreater(allocator, valid_range);
        cell.heap_ptr.* = .{
            .state = .{
                .maximal = .{
                    .slot_idx = @intCast(cache.maximals.items.len),
                    .total_evidence_count = total_evidence_count,
                    .discriminative_evidence_count = discriminative_evidence_count,
                },
            },
            .hash = evidences.hash,
        };
        cache.maximals.appendAssumeCapacity(.{
            .commit_collection = commit_collection,
            .cell = cell,
        });
    }
    cache.map.putAssumeCapacityNoClobberContext(cell.heap_ptr.signature(), {}, hash_context);
}

pub const Cache = struct {
    map: std.HashMapUnmanaged(Signature, void, MapContext, std.hash_map.default_max_load_percentage),
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
        const ordered_maximal_indexes = blk: {
            const maximal_indexes = try allocator.alloc(usize, self.maximals.items.len);
            errdefer allocator.free(maximal_indexes);
            for (maximal_indexes, 0..) |*idx, i|
                idx.* = i;
            const SortContext = struct {
                maximals: []Cache.Maximal,
                num_masks: usize,
                fn lessThan(ctx: @This(), a: usize, b: usize) bool {
                    const maximal_a = ctx.maximals[a].cell.heap_ptr.state.maximal;
                    const maximal_b = ctx.maximals[b].cell.heap_ptr.state.maximal;
                    if (maximal_a.discriminative_evidence_count != maximal_b.discriminative_evidence_count)
                        return maximal_a.discriminative_evidence_count > maximal_b.discriminative_evidence_count;
                    if (maximal_a.total_evidence_count != maximal_b.total_evidence_count)
                        return maximal_a.total_evidence_count > maximal_b.total_evidence_count;
                    const mask_a = ctx.maximals[a].cell.heap_ptr.signature().raw;
                    const mask_b = ctx.maximals[b].cell.heap_ptr.signature().raw;
                    for (0..ctx.num_masks) |mask_idx| {
                        const diff = mask_a[mask_idx] ^ mask_b[mask_idx];
                        if (diff == 0) continue;
                        const first_diff_mask = diff & (0 -% diff);
                        return (mask_a[mask_idx] & first_diff_mask) != 0;
                    }
                    unreachable;
                }
            };
            const ctx: SortContext = .{
                .maximals = self.maximals.items,
                .num_masks = numMasks(bit_length),
            };
            std.sort.pdq(usize, maximal_indexes, ctx, SortContext.lessThan);
            break :blk maximal_indexes;
        };
        defer allocator.free(ordered_maximal_indexes);

        var candidates: std.ArrayListUnmanaged(Candidate) = try .initCapacity(allocator, self.maximals.items.len);
        errdefer {
            for (candidates.items, ordered_maximal_indexes[0..candidates.items.len]) |*candidate, maximal_idx| {
                const maximal = &self.maximals.items[maximal_idx];
                maximal.commit_collection.b = .fromOwnedSlice(candidate.commits.ranges);
                var bit_set = candidate.signature.promote(bit_length);
                bit_set.deinit(allocator);
            }
            candidates.deinit(allocator);
        }
        for (ordered_maximal_indexes) |maximal_idx| {
            const maximal = &self.maximals.items[maximal_idx];
            const commits = try maximal.commit_collection.toOwnedCommitRanges(allocator);
            errdefer maximal.commit_collection.b = .fromOwnedSlice(commits.ranges);
            var sig_bit_map = maximal.cell.heap_ptr.signature().promote(bit_length);
            const signature: Signature = .{ .raw = (try sig_bit_map.clone(allocator)).masks };
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
        pub const Header = struct {
            state: union(enum) {
                maximal: struct {
                    slot_idx: u32,
                    total_evidence_count: u32,
                    discriminative_evidence_count: u32,
                },
                dominated: void,
            },
            hash: u64,
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
    pub const MapContext = struct {
        bit_length: usize,
        pub fn hash(self: MapContext, c: Signature) u64 {
            _ = self;
            const cell: Cache.Cell = .fromSignature(c);
            return cell.heap_ptr.hash;
        }
        pub fn eql(self: MapContext, a: Signature, b: Signature) bool {
            return a.promote(self.bit_length).eql(b.promote(self.bit_length));
        }
    };
    pub const PseudoKey = struct {
        bit_set: std.DynamicBitSetUnmanaged,
        hash: u64,
        pub const Context = struct {
            pub fn hash(self: PseudoKey.Context, c: PseudoKey) u64 {
                _ = self;
                return c.hash;
            }
            pub fn eql(self: PseudoKey.Context, a: PseudoKey, b: Signature) bool {
                _ = self;
                return a.bit_set.eql(b.promote(a.bit_set.bit_length));
            }
        };
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

test "dominance prefix ignores non-discriminative tail bits" {
    var lhs = [_]std.DynamicBitSetUnmanaged.MaskInt{0b101};
    var rhs = [_]std.DynamicBitSetUnmanaged.MaskInt{0b001};

    // bit 2 is outside the discriminative prefix.
    try std.testing.expect(bitSetPrefixSubsetOf(lhs[0..].ptr, rhs[0..].ptr, 2));
    try std.testing.expect(bitSetPrefixSubsetOf(rhs[0..].ptr, lhs[0..].ptr, 2));

    // Once bit 2 becomes discriminative, lhs is no longer a subset of rhs.
    try std.testing.expect(!bitSetPrefixSubsetOf(lhs[0..].ptr, rhs[0..].ptr, 3));
    try std.testing.expect(bitSetPrefixSupersetOf(lhs[0..].ptr, rhs[0..].ptr, 3));
}
