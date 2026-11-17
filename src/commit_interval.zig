const std = @import("std");
const CommitSeqNative = @import("rocksdb_custom.zig").CommitSeqNative;
const CommitSeq = @import("rocksdb_custom.zig").CommitSeq;

pub const CommitIntervalBacking: type = std.meta.Int(@typeInfo(CommitSeqNative).int.signedness, @typeInfo(CommitSeqNative).int.bits * 2);
// max为逻辑低位，min为逻辑高位。在逻辑顺序中，min为排序的主要影响者，max为次要影响者。
pub const CommitInterval = packed struct(CommitIntervalBacking) {
    max: CommitSeqNative,
    min: CommitSeqNative,
    pub fn packMinMax(min: CommitSeqNative, max: CommitSeqNative) CommitInterval {
        std.debug.assert(min <= max);
        return .{ .min = min, .max = max };
    }
};

// 增序比较函数。就是直接将它当成整数进行比较。
pub fn asc(_: void, a: CommitInterval, b: CommitInterval) bool {
    return @as(CommitIntervalBacking, @bitCast(a)) < @as(CommitIntervalBacking, @bitCast(b));
}

/// `CommitCollection`指代一个Commit的非空集合。它的实质是`[]CommitInterval`，但是增加了一层语义：此切片中的所有CommitInterval是严格无重叠的，从小到大排列。
/// 通过Builder构造，持有`[]CommitInterval`的内存，因此不要直接拷贝它。其内容在持有资源期间不可变。发生变化则只能先释放资源后重新构造。
/// `CommitCollection.View`代表其资源的可供拷贝的引用义，生存期不超过生成它的`CommitCollection`。
pub const CommitCollection = struct {
    intervals: []CommitInterval,
    pub const View = struct {
        intervals: []const CommitInterval,
        // 调试时使用，目前未使用
        pub fn eql(c1: CommitCollection.View, c2: CommitCollection.View) bool {
            if (c1.intervals.len != c2.intervals.len) return false;
            for (c1.intervals, 0..) |interval, i| {
                if (interval != c2.intervals[i]) {
                    return false;
                }
            }
            return true;
        }
        pub fn dupe(self: View, allocator: std.mem.Allocator) !CommitCollection {
            return .{ .intervals = try allocator.dupe(CommitInterval, self.intervals) };
        }
        pub fn commitCount(self: View) usize {
            var total: usize = 0;
            for (self.intervals) |interval| total += interval.max - interval.min + 1;
            return total;
        }
        pub fn iter(self: View) Iter {
            return .{
                .view = self,
                .cursor = 0,
                .current = if (self.intervals.len > 0) self.intervals[0].min else unreachable,
            };
        }
        pub const Iter = struct {
            view: View,
            cursor: usize,
            current: CommitSeqNative,
            pub fn next(self: *Iter) ?CommitSeq {
                if (self.cursor > self.view.intervals.len) unreachable;
                if (self.cursor == self.view.intervals.len) return null;
                const to_yield = self.current;
                if (to_yield < self.view.intervals[self.cursor].max) {
                    self.current += 1;
                } else {
                    self.cursor += 1;
                    self.current = if (self.cursor < self.view.intervals.len) self.view.intervals[self.cursor].min else undefined;
                }
                return .fromNative(to_yield);
            }
        };
    };
    pub const Builder = struct {
        b: std.ArrayListUnmanaged(CommitInterval),
        pub const init: Builder = .{ .b = .empty };
        pub fn toOwnedCommitIntervals(self: *Builder, allocator: std.mem.Allocator) !CommitCollection {
            if (self.b.items.len == 0) {
                std.log.err(
                    \\Builded CommitCollection is empty.
                    \\This probably means that the rocksdb database the analysis was based on does not conform to expectations. 
                    \\Use the `vcaligner prep` subcommand to regenerate a valid rocksdb database.
                , .{});
                return error.EmptyCommitIntervals;
            }
            return .{ .intervals = try self.b.toOwnedSlice(allocator) };
        }
        // 在构建过程中添加一整个CommitInterval，并断言这个Interval的min不小于当前最新Interval的min。
        pub fn appendIntervalAssertMinGte(self: *Builder, allocator: std.mem.Allocator, interval: CommitInterval) !void {
            if (self.b.items.len > 0) {
                const previous_interval: *CommitInterval = &self.b.items[self.b.items.len - 1];
                std.debug.assert(interval.min >= previous_interval.min);
                const current_max = previous_interval.max;
                // NOTE: 此判断的意图表达等价于`interval.min <= current_max or interval.min - current_max == 1`
                if (interval.min -| current_max <= 1) {
                    previous_interval.max = @max(current_max, interval.max);
                    return;
                }
            }
            try self.b.append(allocator, interval);
        }
        /// 在构建过程中添加一整个CommitInterval，并假定这个Interval在所有已知当前Interval之后
        pub fn appendIntervalAssumeGreater(self: *Builder, allocator: std.mem.Allocator, interval: CommitInterval) !void {
            if (self.b.items.len > 0) {
                const previous_interval: *CommitInterval = &self.b.items[self.b.items.len - 1];
                if (interval.min <= previous_interval.max) {
                    std.log.err("Input interval min ({d}) not strictly greater than previous interval max ({d})." ++
                        \\
                        \\This probably means that the rocksdb database the analysis was based on does not conform to expectations. 
                        \\Use the `vcaligner prep` subcommand to regenerate a valid rocksdb database.
                    , .{ interval.min, previous_interval.max });
                    return Error.AppendAssumptionViolation;
                }
                if (interval.min - previous_interval.max == 1) {
                    previous_interval.max = interval.max;
                    return;
                }
            }
            try self.b.append(allocator, interval);
        }
        pub fn appendNativeAssumeGreater(self: *Builder, allocator: std.mem.Allocator, ci_native: CommitSeqNative) !void {
            try self.appendIntervalAssumeGreater(allocator, .packMinMax(ci_native, ci_native));
        }
        pub const Error = error{ EmptyCommitIntervals, AppendAssumptionViolation };
    };
    pub fn fromBuilder(builder: *Builder, allocator: std.mem.Allocator) !CommitCollection {
        return builder.toOwnedCommitIntervals(allocator);
    }
    pub fn deinit(self: CommitCollection, allocator: std.mem.Allocator) void {
        allocator.free(self.intervals);
    }
    pub fn view(self: CommitCollection) CommitCollection.View {
        return .{ .intervals = self.intervals };
    }
    /// 将`self`与`other`取交集。`self`应持所有权。`other`可以没有所有权。
    /// 如果交集结果与`self`相同，返回`.unchanged`。
    /// 如果交集结果让`self`变小，`self`的值将就地修改，过程相当于`self`的内容被释放并重新分配内存替换，返回`.restricted`。
    /// 如果交集为空，`self`不变，返回`.empty`。注意CommitCollection语义是非空集合，不支持变为空集合。
    pub fn intersectInPlace(self: *CommitCollection, allocator: std.mem.Allocator, other: CommitCollection.View) !enum { unchanged, restricted, empty } {
        var intersection_builder: std.ArrayList(CommitInterval) = .empty;
        errdefer intersection_builder.deinit(allocator);
        {
            const intervals1: []const CommitInterval = self.intervals;
            const intervals2: []const CommitInterval = other.intervals;
            var cursor1: usize = 0;
            var cursor2: usize = 0;
            var is_full_match: bool = true;
            while (cursor1 < intervals1.len and cursor2 < intervals2.len) {
                const min1 = intervals1[cursor1].min;
                const max1 = intervals1[cursor1].max;
                const min2 = intervals2[cursor2].min;
                const max2 = intervals2[cursor2].max;
                if (max1 < min2) {
                    is_full_match = false;
                    cursor1 += 1;
                    continue;
                } else if (max2 < min1) {
                    cursor2 += 1;
                    continue;
                }
                const inter_min = @max(min1, min2);
                const inter_max = @min(max1, max2);
                std.debug.assert(inter_min <= inter_max);
                if (inter_min != min1 or inter_max != max1) {
                    is_full_match = false;
                }
                try intersection_builder.append(allocator, .packMinMax(inter_min, inter_max));
                if (max1 < max2) cursor1 += 1 else if (max1 > max2) cursor2 += 1 else {
                    cursor1 += 1;
                    cursor2 += 1;
                }
            }
            // 剩余 L1 无交集
            if (cursor1 < intervals1.len) is_full_match = false;
            if (is_full_match and intersection_builder.items.len == intervals1.len) {
                intersection_builder.deinit(allocator); // 丢弃临时分配
                return .unchanged;
            }
            // intervals1的戏份到此为止。作为一个悬垂引用剩余情况不再被需要。
        }
        if (intersection_builder.items.len == 0) {
            intersection_builder.deinit(allocator);
            return .empty;
        } else {
            const intervals = try intersection_builder.toOwnedSlice(allocator);
            self.deinit(allocator);
            self.* = .{ .intervals = intervals };
            return .restricted;
        }
    }
};

// 假定各列表内的interval都是从小到大排序的，否则不成立。
pub fn intersection(allocator: std.mem.Allocator, c1: CommitCollection.View, c2: CommitCollection.View) !CommitCollection {
    const l1: []const CommitInterval = c1.intervals;
    const l2: []const CommitInterval = c2.intervals;
    var result: std.ArrayList(CommitInterval) = .empty;
    errdefer result.deinit(allocator);
    var cursor1: usize = 0;
    var cursor2: usize = 0;
    while (cursor1 < l1.len and cursor2 < l2.len) {
        const min1 = l1[cursor1].min;
        const max1 = l1[cursor1].max;
        const min2 = l2[cursor2].min;
        const max2 = l2[cursor2].max;
        if (max1 < min2) {
            cursor1 += 1;
            continue;
        } else if (max2 < min1) {
            cursor2 += 1;
            continue;
        }
        const inter_min = @max(min1, min2);
        const inter_max = @min(max1, max2);
        std.debug.assert(inter_min <= inter_max);
        try result.append(allocator, .packMinMax(inter_min, inter_max));
        if (max1 < max2) cursor1 += 1 else if (max2 < max1) cursor2 += 1 else {
            cursor1 += 1;
            cursor2 += 1;
        }
    }
    return .{ .intervals = try result.toOwnedSlice(allocator) };
}

pub fn unionCollections(
    allocator: std.mem.Allocator,
    collections: []const CommitCollection,
) !CommitCollection {
    if (collections.len == 0) std.debug.panic(
        \\unionCollections assume the collections is not empty.
        \\This is a programming error.
    , .{});
    if (collections.len == 1) return .{ .intervals = try allocator.dupe(CommitInterval, collections[0].intervals) };
    const all_intervals = try allocator.alloc(CommitInterval, total_intervals: {
        var total_intervals: usize = 0;
        for (collections) |collection| {
            // Collection的设计为不可能有长度为0的interval。
            std.debug.assert(collection.intervals.len > 0);
            total_intervals += collection.intervals.len;
        }
        break :total_intervals total_intervals;
    });
    defer allocator.free(all_intervals);
    {
        var offset: usize = 0;
        for (collections) |col| {
            @memcpy(all_intervals[offset..][0..col.intervals.len], col.intervals);
            offset += col.intervals.len;
        }
    }
    std.sort.pdq(CommitInterval, all_intervals, {}, struct {
        fn lessThan(_: void, a: CommitInterval, b: CommitInterval) bool {
            return a.min < b.min;
        }
    }.lessThan);

    var builder: CommitCollection.Builder = .init;
    errdefer builder.b.deinit(allocator);
    for (all_intervals) |interval| try builder.appendIntervalAssertMinGte(allocator, interval);
    return try builder.toOwnedCommitIntervals(allocator);
}

fn testIntersectInPlace(
    intervals_self: []const CommitInterval,
    intervals_other: []const CommitInterval,
    expect_result: anytype,
    expect_intersection: []const CommitInterval,
) !void {
    const allocator = std.testing.allocator;
    var self: CommitCollection = .{ .intervals = try allocator.dupe(CommitInterval, intervals_self) };
    defer self.deinit(allocator);
    const other: CommitCollection.View = .{ .intervals = intervals_other };
    const result = try self.intersectInPlace(allocator, other);
    try std.testing.expectEqual(expect_result, result);
    try std.testing.expectEqualSlices(CommitInterval, expect_intersection, self.intervals);
}
test "IntersectInPlace" {
    try testIntersectInPlace(
        &.{ .packMinMax(10, 20), .packMinMax(30, 40) },
        &.{ .packMinMax(10, 20), .packMinMax(30, 40) },
        .unchanged,
        &.{ .packMinMax(10, 20), .packMinMax(30, 40) },
    );
    try testIntersectInPlace(
        &.{ .packMinMax(10, 20), .packMinMax(30, 40) },
        &.{.packMinMax(15, 35)},
        .restricted,
        &.{ .packMinMax(15, 20), .packMinMax(30, 35) },
    );
    try testIntersectInPlace(
        &.{ .packMinMax(10, 20), .packMinMax(30, 40) },
        &.{ .packMinMax(50, 60), .packMinMax(70, 80) },
        .empty,
        &.{ .packMinMax(10, 20), .packMinMax(30, 40) },
    );
    try testIntersectInPlace(
        &.{ .packMinMax(10, 20), .packMinMax(30, 40) },
        &.{ .packMinMax(0, 50), .packMinMax(100, 200) },
        .unchanged,
        &.{ .packMinMax(10, 20), .packMinMax(30, 40) },
    );
    try testIntersectInPlace(
        &.{.packMinMax(10, 20)},
        &.{.packMinMax(21, 30)},
        .empty,
        &.{.packMinMax(10, 20)},
    );
    try testIntersectInPlace(
        &.{.packMinMax(10, 20)},
        &.{.packMinMax(20, 30)},
        .restricted,
        &.{.packMinMax(20, 20)},
    );
    try testIntersectInPlace(
        &.{
            .packMinMax(10, 20),
            .packMinMax(30, 40),
            .packMinMax(50, 60),
            .packMinMax(70, 80),
        },
        &.{
            .packMinMax(0, 15),
            .packMinMax(35, 55),
            .packMinMax(75, 100),
        },
        .restricted,
        &.{
            .packMinMax(10, 15),
            .packMinMax(35, 40),
            .packMinMax(50, 55),
            .packMinMax(75, 80),
        },
    );
    try testIntersectInPlace(
        &.{.packMinMax(10, 30)},
        &.{ .packMinMax(0, 15), .packMinMax(20, 40) },
        .restricted,
        &.{ .packMinMax(10, 15), .packMinMax(20, 30) },
    );
}
