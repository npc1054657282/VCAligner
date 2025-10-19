const std = @import("std");
const CommitSeqNative = @import("rocksdb_custom.zig").CommitSeqNative;
const CommitSeq = @import("rocksdb_custom.zig").CommitSeq;

pub const CommitRangeBacking: type = std.meta.Int(@typeInfo(CommitSeqNative).int.signedness, @typeInfo(CommitSeqNative).int.bits * 2);
// end为逻辑低位，start为逻辑高位。在逻辑顺序中，start为排序的主要影响者，end为次要影响者。
pub const CommitRange = packed struct(CommitRangeBacking) {
    end: CommitSeqNative,
    start: CommitSeqNative,
    pub fn packStartEnd(start: CommitSeqNative, end: CommitSeqNative) CommitRange {
        return .{ .start = start, .end = end };
    }
};

// 增序比较函数。就是直接将它当成整数进行比较。
pub fn asc(_: void, a: CommitRange, b: CommitRange) bool {
    return @as(CommitRangeBacking, @bitCast(a)) < @as(CommitRangeBacking, @bitCast(b));
}

/// `CommitCollection`指代一个Commit的非空集合。它的实质是`[]CommitRange`，但是增加了一层语义：此切片中的所有CommitRange是严格无重叠的，从小到大排列。
/// 通过Builder构造，持有`[]CommitRange`的内存，因此不要直接拷贝它。其内容在持有资源期间不可变。发生变化则只能先释放资源后重新构造。
/// `CommitCollection.View`代表其资源的可供拷贝的引用义，生存期不超过生成它的`CommitCollection`。
pub const CommitCollection = struct {
    ranges: []CommitRange,
    pub const View = struct {
        ranges: []const CommitRange,
        // 调试时使用，目前未使用
        pub fn eql(c1: CommitCollection.View, c2: CommitCollection.View) bool {
            if (c1.ranges.len != c2.ranges.len) return false;
            for (c1.ranges, 0..) |r, i| {
                if (r != c2.ranges[i]) {
                    return false;
                }
            }
            return true;
        }
        pub fn dupe(self: View, allocator: std.mem.Allocator) !CommitCollection {
            return .{ .ranges = try allocator.dupe(CommitRange, self.ranges) };
        }
    };
    pub const Builder = struct {
        b: std.ArrayList(CommitRange),
        maybe_last_range: ?CommitRange,
        pub const init: Builder = .{ .b = .empty, .maybe_last_range = null };
        /// 在构建过程中添加新值，并假定这个值比已知所有值都要更大，以省去重新排序
        pub fn appendAssumeGreaterNative(self: *Builder, allocator: std.mem.Allocator, ci_native: CommitSeqNative) !void {
            if (self.maybe_last_range) |last_range| {
                std.debug.assert(ci_native > last_range.end and last_range.end >= last_range.start);
                if (ci_native == last_range.end + 1) {
                    self.maybe_last_range = .packStartEnd(last_range.start, ci_native);
                } else {
                    try self.b.append(allocator, last_range);
                    self.maybe_last_range = .packStartEnd(ci_native, ci_native);
                }
            } else {
                self.maybe_last_range = .packStartEnd(ci_native, ci_native);
            }
        }
        /// 将内容转换为一个拥有所有权的CommitRanges
        pub fn toOwnedCommitRanges(self: *Builder, allocator: std.mem.Allocator) !CommitCollection {
            if (self.maybe_last_range) |last_range| {
                try self.b.append(allocator, last_range);
            } else return error.EmptyCommitRanges;
            return .{ .ranges = try self.b.toOwnedSlice(allocator) };
        }
    };
    pub fn fromBuilder(builder: *Builder, allocator: std.mem.Allocator) !CommitCollection {
        return builder.toOwnedCommitRanges(allocator);
    }
    pub fn deinit(self: CommitCollection, allocator: std.mem.Allocator) void {
        allocator.free(self.ranges);
    }
    pub fn view(self: CommitCollection) CommitCollection.View {
        return .{ .ranges = self.ranges };
    }
    /// 将`self`与`other`取交集。`self`应持所有权。`other`可以没有所有权。
    /// 如果交集结果与`self`相同，返回`.unchanged`。
    /// 如果交集结果让`self`变小，`self`的值将就地修改，过程相当于`self`的内容被释放并重新分配内存替换，返回`.restricted`。
    /// 如果交集为空，`self`不变，返回`.empty`。注意CommitCollection语义是非空集合，不支持变为空集合。
    pub fn intersectInPlace(self: *CommitCollection, allocator: std.mem.Allocator, other: CommitCollection.View) !enum { unchanged, restricted, empty } {
        var intersection_builder: std.ArrayList(CommitRange) = .empty;
        errdefer intersection_builder.deinit(allocator);
        {
            const ranges1: []const CommitRange = self.ranges;
            const ranges2: []const CommitRange = other.ranges;
            var cursor1: usize = 0;
            var cursor2: usize = 0;
            var is_full_match: bool = true;
            while (cursor1 < ranges1.len and cursor2 < ranges2.len) {
                const start1 = ranges1[cursor1].start;
                const end1 = ranges1[cursor1].end;
                const start2 = ranges2[cursor2].start;
                const end2 = ranges2[cursor2].end;
                if (end1 < start2) {
                    is_full_match = false;
                    cursor1 += 1;
                    continue;
                } else if (end2 < start1) {
                    cursor2 += 1;
                    continue;
                }
                const inter_start = @max(start1, start2);
                const inter_end = @min(end1, end2);
                std.debug.assert(inter_start <= inter_end);
                if (inter_start != start1 or inter_end != end1) {
                    is_full_match = false;
                }
                try intersection_builder.append(allocator, .packStartEnd(inter_start, inter_end));
                if (end1 < end2) cursor1 += 1 else if (end1 > end2) cursor2 += 1 else {
                    cursor1 += 1;
                    cursor2 += 1;
                }
            }
            // 剩余 L1 无交集
            if (cursor1 < ranges1.len) is_full_match = false;
            if (is_full_match and intersection_builder.items.len == ranges1.len) {
                intersection_builder.deinit(allocator); // 丢弃临时分配
                return .unchanged;
            }
            // ranges1的戏份到此为止。作为一个悬垂引用剩余情况不再被需要。
        }
        if (intersection_builder.items.len == 0) {
            intersection_builder.deinit(allocator);
            return .empty;
        } else {
            self.deinit(allocator);
            self.* = .{ .ranges = try intersection_builder.toOwnedSlice(allocator) };
            return .restricted;
        }
    }
};

// 假定各列表内的range都是从小到大排序的，否则不成立。
pub fn intersection(allocator: std.mem.Allocator, c1: CommitCollection.View, c2: CommitCollection.View) !CommitCollection {
    const l1: []const CommitRange = c1.ranges;
    const l2: []const CommitRange = c2.ranges;
    var result: std.ArrayList(CommitRange) = .empty;
    errdefer result.deinit(allocator);
    var cursor1: usize = 0;
    var cursor2: usize = 0;
    while (cursor1 < l1.len and cursor2 < l2.len) {
        const start1 = l1[cursor1].start;
        const end1 = l1[cursor1].end;
        const start2 = l2[cursor2].start;
        const end2 = l2[cursor2].end;
        if (end1 < start2) {
            cursor1 += 1;
            continue;
        } else if (end2 < start1) {
            cursor2 += 1;
            continue;
        }
        const inter_start = @max(start1, start2);
        const inter_end = @min(end1, end2);
        std.debug.assert(inter_start <= inter_end);
        try result.append(allocator, .packStartEnd(inter_start, inter_end));
        if (end1 < end2) cursor1 += 1 else if (end2 < end1) cursor2 += 1 else {
            cursor1 += 1;
            cursor2 += 1;
        }
    }
    return .{ .ranges = try result.toOwnedSlice(allocator) };
}

pub const IntersectionAsymmetricResult = union(enum) {
    equal_to_l1: void,
    empty: void,
    different: []CommitRange,
};
// 不对称的交集，l1是主范围，l2是挑战者。如果结果和l1完全相同，结果为空，返回特殊结果。否则返回新结果。
pub fn intersectionAsymmetric(allocator: std.mem.Allocator, l1: []const CommitRange, l2: []const CommitRange) !IntersectionAsymmetricResult {
    if (l1.len == 0 or l2.len == 0) return .empty;
    var result: std.ArrayList(CommitRange) = .empty;
    errdefer result.deinit(allocator);

    var cursor1: usize = 0;
    var cursor2: usize = 0;
    var is_full_match: bool = true;

    while (cursor1 < l1.len and cursor2 < l2.len) {
        const start1 = l1[cursor1].start;
        const end1 = l1[cursor1].end;
        const start2 = l2[cursor2].start;
        const end2 = l2[cursor2].end;
        if (end1 < start2) {
            is_full_match = false;
            cursor1 += 1;
            continue;
        } else if (end2 < start1) {
            cursor2 += 1;
            continue;
        }
        const inter_start = @max(start1, start2);
        const inter_end = @min(end1, end2);
        std.debug.assert(inter_start <= inter_end);
        if (inter_start != start1 or inter_end != end1) {
            is_full_match = false;
        }
        try result.append(allocator, .packStartEnd(inter_start, inter_end));
        if (end1 < end2) cursor1 += 1 else if (end1 > end2) cursor2 += 1 else {
            cursor1 += 1;
            cursor2 += 1;
        }
    }
    // 剩余 L1 无交集
    if (cursor1 < l1.len) is_full_match = false;
    if (is_full_match and result.items.len == l1.len) {
        result.deinit(allocator); // 丢弃临时分配
        return .equal_to_l1;
    } else if (result.items.len == 0) {
        result.deinit(allocator);
        return .empty;
    } else {
        return .{ .different = try result.toOwnedSlice(allocator) };
    }
}
