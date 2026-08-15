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
pub const PathRankNative = u32;
pub const PathRank = Seq(PathRankNative, .big);
pub const BlobCountNative = u32;
pub const BlobCount = Seq(BlobCountNative, .big);
pub const PathRankBlobCountKey = extern struct {
    path_rank: PathRank align(1),
    blob_count: BlobCount align(1),
};

pub const CollumFamily = enum {
    // Cumulative 列族，构造时一边解析一边写入，可增量
    // 键为blob-path-id和commit-id并列(Key)，值为空
    bpi2ci,
    // 键为path-id(PathSeq)，值为path
    pi2p,
    // 键为blob和path-id并列(BlobPathKey)，值为blob-path-id(BlobPathSeq)
    b_pi2bpi,
    // 键为commit-id(CommitSeq)，值为commit
    ci2c,
    // Full-Rebuild 列族，构造结束以后一次性通过sstWriter写入，不可增量，每次写入全部替换
    // 键为path-rank和blob-count并列，值为path
    pr_bc2pi,
};
pub const cf_names: std.enums.EnumArray(CollumFamily, [*:0]const u8) = .init(.{
    // XXX: 将来考虑默认列族改为存放元数据，专设bpi2ci列族。
    // 当前考虑到复用已有分析数据的兼容性，仍然设计为bpi2ci使用default列族。
    .bpi2ci = "default",
    .pi2p = "pi2p",
    .b_pi2bpi = "b_pi2bpi",
    .ci2c = "ci2c",
    .pr_bc2pi = "pr2pi",
});

// 在读取rocksdb时，应用全局遍历的配置。
// 如果读取的rocksdb的列族的键是固定长度的（有确定类型的），且没有配置其他比较器，则可以使用此函数配置读取选项。
// 在本项目中，适用于：增量模式加载时的ci2c列族、pr_bc2pi列族、b_pi2bpi列族的读取；分析过程中pr_bc2pi列族的读取。
pub fn applyFullScanOfOrderPreservingTypedKeyToReadOptions(
    roptions: *c.rocksdb_readoptions_t,
    K: type,
) void {
    // 全局遍历一次，缓存没有意义，不使用缓存避免污染。
    c.rocksdb_readoptions_set_fill_cache(roptions, 0);
    // 总序遍历，按全局键序遍历整个列族。
    // 主要是规避prefix extractor的影响。prefix extractor可能会截断key，导致无法全局遍历。
    c.rocksdb_readoptions_set_total_order_seek(roptions, 1);
    c.rocksdb_readoptions_set_auto_readahead_size(roptions, 1);
    // 为了让`readahead`实际生效，配置`iterate_upper_bound`为usize最大值。
    // [参见](https://github.com/facebook/rocksdb/blob/6a202c5570d9aca11a23c5b1a78019f8be245463/include/rocksdb/options.h#L2111-L2135)
    const key_upper_bound: [@sizeOf(K) + 1]u8 = @as([@sizeOf(K)]u8, @splat(0xff)) ++ [1]u8{0};
    c.rocksdb_readoptions_set_iterate_upper_bound(roptions, &key_upper_bound, key_upper_bound.len);
}
