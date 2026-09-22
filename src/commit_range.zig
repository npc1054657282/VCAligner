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
        pub fn commitCount(self: View) usize {
            var total: usize = 0;
            for (self.ranges) |range| total += range.end - range.start + 1;
            return total;
        }
        pub fn iter(self: View) Iter {
            return .{
                .view = self,
                .cursor = 0,
                .current = if (self.ranges.len > 0) self.ranges[0].start else unreachable,
            };
        }
        pub const Iter = struct {
            view: View,
            cursor: usize,
            current: CommitSeqNative,
            pub fn next(self: *Iter) ?CommitSeq {
                if (self.cursor > self.view.ranges.len) unreachable;
                if (self.cursor == self.view.ranges.len) return null;
                const to_yield = self.current;
                if (to_yield < self.view.ranges[self.cursor].end) {
                    self.current += 1;
                } else {
                    self.cursor += 1;
                    self.current = if (self.cursor < self.view.ranges.len) self.view.ranges[self.cursor].start else undefined;
                }
                return .fromNative(to_yield);
            }
        };
    };
    pub const Builder = struct {
        b: std.ArrayListUnmanaged(CommitRange),
        pub const init: Builder = .{ .b = .empty };
        pub fn toOwnedCommitRanges(self: *Builder, allocator: std.mem.Allocator) !CommitCollection {
            if (self.b.items.len == 0) {
                std.log.err(
                    \\Builded CommitCollection is empty.
                    \\This probably means that the rocksdb database the analysis was based on does not conform to expectations. 
                    \\Use the `vcaligner prep` subcommand to regenerate a valid rocksdb database.
                , .{});
                return error.EmptyCommitRanges;
            }
            return .{ .ranges = try self.b.toOwnedSlice(allocator) };
        }
        // 在构建过程中添加一整个CommitRange，并断言这个Range的start不小于当前最新Range的start
        pub fn appendRangeAssertStartGte(self: *Builder, allocator: std.mem.Allocator, range: CommitRange) !void {
            if (self.b.items.len > 0) {
                const last_range: *CommitRange = &self.b.items[self.b.items.len - 1];
                std.debug.assert(range.start >= last_range.start);
                const current_end = last_range.end;
                if (range.start <= current_end + 1) {
                    last_range.end = @max(current_end, range.end);
                    return;
                }
            }
            try self.b.append(allocator, range);
        }
        /// 在构建过程中添加一整个CommitRange，并假定这个Range在所有已知当前Range之后
        pub fn appendRangeAssumeGreater(self: *Builder, allocator: std.mem.Allocator, range: CommitRange) !void {
            if (self.b.items.len > 0) {
                const last_range: *CommitRange = &self.b.items[self.b.items.len - 1];
                if (range.start <= last_range.end) {
                    std.log.err("Input range start ({d}) not strictly greater than last range end ({d})." ++
                        \\
                        \\This probably means that the rocksdb database the analysis was based on does not conform to expectations. 
                        \\Use the `vcaligner prep` subcommand to regenerate a valid rocksdb database.
                    , .{ range.start, last_range.end });
                    return Error.AppendAssumptionViolation;
                }
                if (range.start == last_range.end + 1) {
                    last_range.end = range.end;
                    return;
                }
            }
            try self.b.append(allocator, range);
        }
        pub fn appendNativeAssumeGreater(self: *Builder, allocator: std.mem.Allocator, ci_native: CommitSeqNative) !void {
            try self.appendRangeAssumeGreater(allocator, .packStartEnd(ci_native, ci_native));
        }
        pub const Error = error{ EmptyCommitRanges, AppendAssumptionViolation };
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
            const ranges = try intersection_builder.toOwnedSlice(allocator);
            self.deinit(allocator);
            self.* = .{ .ranges = ranges };
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

pub fn unionCollections(
    allocator: std.mem.Allocator,
    collections: []const CommitCollection,
) !CommitCollection {
    if (collections.len == 0) std.debug.panic(
        \\unionCollections assume the collections is not empty.
        \\This is a programming error.
    , .{});
    if (collections.len == 1) return .{ .ranges = try allocator.dupe(CommitRange, collections[0].ranges) };
    const all_ranges = try allocator.alloc(CommitRange, total_ranges: {
        var total_ranges: usize = 0;
        for (collections) |collection| {
            // Collection的设计为不可能有长度为0的range。
            std.debug.assert(collection.ranges.len > 0);
            total_ranges += collection.ranges.len;
        }
        break :total_ranges total_ranges;
    });
    defer allocator.free(all_ranges);
    {
        var offset: usize = 0;
        for (collections) |col| {
            @memcpy(all_ranges[offset..][0..col.ranges.len], col.ranges);
            offset += col.ranges.len;
        }
    }
    std.sort.pdq(CommitRange, all_ranges, {}, struct {
        fn lessThan(_: void, a: CommitRange, b: CommitRange) bool {
            return a.start < b.start;
        }
    }.lessThan);

    var builder: CommitCollection.Builder = .init;
    errdefer builder.b.deinit(allocator);
    for (all_ranges) |range| try builder.appendRangeAssertStartGte(allocator, range);
    return try builder.toOwnedCommitRanges(allocator);
}

fn testIntersectInPlace(
    ranges_self: []const CommitRange,
    ranges_other: []const CommitRange,
    expect_result: anytype,
    expect_intersection: []const CommitRange,
) !void {
    const allocator = std.testing.allocator;
    var self: CommitCollection = .{ .ranges = try allocator.dupe(CommitRange, ranges_self) };
    defer self.deinit(allocator);
    const other: CommitCollection.View = .{ .ranges = ranges_other };
    const result = try self.intersectInPlace(allocator, other);
    try std.testing.expectEqual(expect_result, result);
    try std.testing.expectEqualSlices(CommitRange, expect_intersection, self.ranges);
}
test "IntersectInPlace" {
    try testIntersectInPlace(
        &.{ .packStartEnd(10, 20), .packStartEnd(30, 40) },
        &.{ .packStartEnd(10, 20), .packStartEnd(30, 40) },
        .unchanged,
        &.{ .packStartEnd(10, 20), .packStartEnd(30, 40) },
    );
    try testIntersectInPlace(
        &.{ .packStartEnd(10, 20), .packStartEnd(30, 40) },
        &.{.packStartEnd(15, 35)},
        .restricted,
        &.{ .packStartEnd(15, 20), .packStartEnd(30, 35) },
    );
    try testIntersectInPlace(
        &.{ .packStartEnd(10, 20), .packStartEnd(30, 40) },
        &.{ .packStartEnd(50, 60), .packStartEnd(70, 80) },
        .empty,
        &.{ .packStartEnd(10, 20), .packStartEnd(30, 40) },
    );
    try testIntersectInPlace(
        &.{ .packStartEnd(10, 20), .packStartEnd(30, 40) },
        &.{ .packStartEnd(0, 50), .packStartEnd(100, 200) },
        .unchanged,
        &.{ .packStartEnd(10, 20), .packStartEnd(30, 40) },
    );
    try testIntersectInPlace(
        &.{.packStartEnd(10, 20)},
        &.{.packStartEnd(21, 30)},
        .empty,
        &.{.packStartEnd(10, 20)},
    );
    try testIntersectInPlace(
        &.{.packStartEnd(10, 20)},
        &.{.packStartEnd(20, 30)},
        .restricted,
        &.{.packStartEnd(20, 20)},
    );
    try testIntersectInPlace(
        &.{
            .packStartEnd(10, 20),
            .packStartEnd(30, 40),
            .packStartEnd(50, 60),
            .packStartEnd(70, 80),
        },
        &.{
            .packStartEnd(0, 15),
            .packStartEnd(35, 55),
            .packStartEnd(75, 100),
        },
        .restricted,
        &.{
            .packStartEnd(10, 15),
            .packStartEnd(35, 40),
            .packStartEnd(50, 55),
            .packStartEnd(75, 80),
        },
    );
    try testIntersectInPlace(
        &.{.packStartEnd(10, 30)},
        &.{ .packStartEnd(0, 15), .packStartEnd(20, 40) },
        .restricted,
        &.{ .packStartEnd(10, 15), .packStartEnd(20, 30) },
    );
}
