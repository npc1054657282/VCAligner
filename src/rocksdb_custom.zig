const std = @import("std");
const c = @import("c.zig").c;
const vcaligner = @import("vcaligner");
fn Seq(comptime Native: type, comptime e: std.builtin.Endian) type {
    return enum(Native) {
        _,
        pub const endian = e;
        pub fn fromNative(n: Native) @This() {
            return @enumFromInt(std.mem.nativeTo(Native, n, e));
        }
        pub fn toNative(self: @This()) Native {
            return std.mem.toNative(Native, @intFromEnum(self), e);
        }
    };
}
pub const CommitSeqNative = u32;
pub const CommitSeq = Seq(CommitSeqNative, .big);
// Array hash map的`count()`返回类型为`usize`，与`hash map`的`u32`有显著不同。这是因为涉及索引，用`usize`有很大方便。
// 但实际上pathSeq只需要`u32`足矣。
pub const PathSeqNative = u32;
pub const PathSeq = Seq(PathSeqNative, .big);
pub const BlobPathKey = extern struct {
    blob_hash: c.git_oid align(1),
    path_seq: PathSeq align(1),
};
pub const BlobPathSeqNative = u32;
pub const BlobPathSeq = Seq(BlobPathSeqNative, .big);
pub const Key = extern struct {
    blob_path_seq: BlobPathSeq align(1),
    commit_seq: CommitSeq align(1),
};
// 一个范围。高位是范围起始值。低位是范围结束值。
const commit_range = @import("commit_range.zig");
const CommitRange = commit_range.CommitRange;
