const std = @import("std");
const vcaligner = @import("vcaligner");
const c = vcaligner.c_helper.c;
const analysis = @import("analysis.zig");

pub const PerBlobAnalysed = struct {
    _: void align(std.atomic.cache_line),
    analyser_id: usize,
    // 以下堆上内容均通过其所属analyser的result_recycling_arena分配。
    // 发生错误不需要标记哪些需要释放哪些不需要释放，统一由result_recycling_arena集体释放。
    repo_path_seqs: []vcaligner.rocksdb_custom.PathSeq,
    commit_collections_per_repo_path: [*]vcaligner.commit_range.CommitCollection,
    topologies: union(enum) {
        // 不需要tag，因为如果分析了，实际类别与repo_path_seqs的数量挂钩。
        analysed: union {
            // 没有repo path seq
            none: void,
            // 只有一个repo path seq。实际上就是`commit_collections_per_repo_path[0].view()`
            single: vcaligner.commit_range.CommitCollection.View,
            integer_bitset: struct {
                shapes: []std.bit_set.IntegerBitSet(@bitSizeOf(usize)),
                commit_collections_per_topology_shape: [*]vcaligner.commit_range.CommitCollection,
            },
            dynamic_bitset: struct {
                shapes: []@FieldType(std.bit_set.DynamicBitSetUnmanaged, "masks"),
                commit_collections_per_topology_shape: [*]vcaligner.commit_range.CommitCollection,
            },
        },
        // 表现形式和single相同，但是理由不同
        // 这个并非只有一个repo path seq，只是此blob被过滤了，不再进行topology的分析。
        unanalysed: vcaligner.commit_range.CommitCollection.View,
    },
};
pub const BlobAnalyserStation = struct {
    _: void align(std.atomic.cache_line),
    result_recycling_arena_state: vcaligner.ExclusiveRecyclingArena(0),
    scratch_recycling_arena_state: vcaligner.ExclusiveRecyclingArena(0),
};

pub fn analyseBlobTopology(
    blob_hashes_entry: []const analysis.ReleaseArtifactBlobManifest.Entry,
    blobs_info_out: [*]PerBlobAnalysed,
    pool: *vcaligner.Pool,
    storage: vcaligner.cli.ana_runner.Storage,
    analyser_ctxs: []BlobAnalyserStation,
) void {
    var wait_group = .{};
    defer pool.waitAndWork(&wait_group);
    for (blobs_info_out[0..blob_hashes_entry.len], 0..) |*per_blob_to_be_analysed, i| {
        pool.spawnWgId(&wait_group, analyseBlobTopologyTask, .{
            blob_hashes_entry[i].blob_hash,
            per_blob_to_be_analysed,
            storage,
            analyser_ctxs,
        });
    }
}

pub fn analyseBlobTopologyTask(
    thrd_id: usize,
    blob_hash: c.git_oid,
    blob_info_out: *PerBlobAnalysed,
    storage: vcaligner.cli.ana_runner.Storage,
    analyser_ctxs: []BlobAnalyserStation,
) void {
    _ = thrd_id;
    _ = blob_hash;
    _ = blob_info_out;
    _ = storage;
    _ = analyser_ctxs;
}
