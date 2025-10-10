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

// 假定各列表内的range都是从小到大排序的，否则不成立。
pub fn intersection(allocator: std.mem.Allocator, l1: []const CommitRange, l2: []const CommitRange) ![]CommitRange {
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
    return result.toOwnedSlice(allocator);
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

// 调试时使用，目前未使用
pub fn eql(l1: []const CommitRange, l2: []const CommitRange) bool {
    if (l1.len != l2.len) return false;
    for (l1, 0..) |r, i| {
        if (r != l2[i]) {
            return false;
        }
    }
    return true;
}
