const std = @import("std");
pub const CommitSeq = @import("rocksdb_custom.zig").CommitSeq;
pub const CommitRange = std.meta.Int(@typeInfo(CommitSeq).int.signedness, @typeInfo(CommitSeq).int.bits * 2);

pub fn getStart(r: CommitRange) CommitSeq {
    return @intCast(r >> (@sizeOf(CommitSeq) * 8));
}

pub fn getEnd(r: CommitRange) CommitSeq {
    return @truncate(r);
}

pub fn packStartEnd(start: CommitSeq, end: CommitSeq) CommitRange {
    return (@as(CommitRange, start) << (@sizeOf(CommitSeq) * 8)) | end;
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
