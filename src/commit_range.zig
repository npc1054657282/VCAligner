const std = @import("std");
const CommitSeq = @import("rocksdb_custom.zig").CommitSeq;
pub const CommitSeqNative = CommitSeq;
pub const CommitRange = std.meta.Int(@typeInfo(CommitSeq).int.signedness, @typeInfo(CommitSeq).int.bits * 2);

pub fn getStart(r: CommitRange) CommitSeqNative {
    return @intCast(r >> (@sizeOf(CommitSeqNative) * 8));
}

pub fn getEnd(r: CommitRange) CommitSeqNative {
    return @truncate(r);
}

pub fn packStartEnd(start: CommitSeqNative, end: CommitSeqNative) CommitRange {
    return (@as(CommitRange, start) << (@sizeOf(CommitSeqNative) * 8)) | end;
}

// 假定各列表内的range都是从小到大排序的，否则不成立。
pub fn intersection(allocator: std.mem.Allocator, l1: []const CommitRange, l2: []const CommitRange) ![]CommitRange {
    var result: std.ArrayList(CommitRange) = .empty;
    errdefer result.deinit(allocator);
    var cursor1: usize = 0;
    var cursor2: usize = 0;
    while (cursor1 < l1.len and cursor2 < l2.len) {
        const start1 = getStart(l1[cursor1]);
        const end1 = getEnd(l1[cursor1]);
        const start2 = getStart(l2[cursor2]);
        const end2 = getEnd(l2[cursor2]);
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
        try result.append(allocator, packStartEnd(inter_start, inter_end));
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
        const start1 = getStart(l1[cursor1]);
        const end1 = getEnd(l1[cursor1]);
        const start2 = getStart(l2[cursor2]);
        const end2 = getEnd(l2[cursor2]);
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
        try result.append(allocator, packStartEnd(inter_start, inter_end));
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
        if (getStart(r) != getStart(l2[i]) or
            getEnd(r) != getEnd(l2[i]))
        {
            return false;
        }
    }
    return true;
}
