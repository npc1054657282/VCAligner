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
    result_recycling_arena_state: vcaligner.ExclusiveRecyclingArena(0).State,
    scratch_recycling_arena_state: vcaligner.ExclusiveRecyclingArena(0).State,
};

pub fn analyseBlobTopology(
    blob_hashes_entry: []const analysis.ReleaseArtifactBlobManifest.Entry,
    blobs_info_out: [*]PerBlobAnalysed,
    pool: *vcaligner.Pool,
    storage: vcaligner.cli.ana_runner.Storage,
    analyser_ctxs: []BlobAnalyserStation,
    gpac: vcaligner.gpa.Concurrent,
) void {
    var wait_group = .{};
    defer pool.waitAndWork(&wait_group);
    for (blobs_info_out[0..blob_hashes_entry.len], 0..) |*per_blob_to_be_analysed, i| {
        pool.spawnWgId(&wait_group, analyseBlobTopologySubTask, .{
            blob_hashes_entry[i].blob_hash,
            per_blob_to_be_analysed,
            storage,
            analyser_ctxs,
            gpac,
        });
    }
}

pub fn analyseBlobTopologySubTask(
    thrd_id: usize,
    blob_hash: c.git_oid,
    blob_info_out: *PerBlobAnalysed,
    storage: vcaligner.cli.ana_runner.Storage,
    analyser_ctxs: []BlobAnalyserStation,
    gpac: vcaligner.gpa.Concurrent,
) void {
    analyseBlobTopologySub(
        thrd_id,
        blob_hash,
        blob_info_out,
        storage,
        analyser_ctxs,
        gpac,
    ) catch {
        vcaligner.crash_dump.dumpAndCrash(@src());
    };
}

pub fn analyseBlobTopologySub(
    thrd_id: usize,
    blob_hash: c.git_oid,
    blob_info_out: *PerBlobAnalysed,
    storage: vcaligner.cli.ana_runner.Storage,
    analyser_ctxs: []BlobAnalyserStation,
    gpac: vcaligner.gpa.Concurrent,
) !void {
    var scratch_handle = analyser_ctxs[thrd_id].scratch_recycling_arena_state.handle(gpac.allocator);
    defer scratch_handle.reset();
    const scratch_allocator = scratch_handle.allocator();
    var result_handle = analyser_ctxs[thrd_id].result_recycling_arena_state.handle(gpac.allocator);
    const result_allocator = result_handle.allocator();
    const repo_path_seqs, const commit_collections_per_repo_path = commit_collections_per_repo_path: {
        const prefix_scan_roptions = blk: {
            const roptions = c.rocksdb_readoptions_create().?;
            vcaligner.rocksdb_custom.applyPrefixScanToReadOptions(roptions);
            break :blk roptions;
        };
        defer c.rocksdb_readoptions_destroy(prefix_scan_roptions);
        const repo_path_seqs: []vcaligner.rocksdb_custom.PathSeq, const blob_path_seqs: std.ArrayListUnmanaged(vcaligner.rocksdb_custom.BlobPathSeq) = repo_path_seqs: {
            var repo_path_seqs: std.ArrayListUnmanaged(vcaligner.rocksdb_custom.PathSeq) = .empty;
            errdefer repo_path_seqs.deinit(result_allocator);
            var blob_path_seqs: std.ArrayListUnmanaged(vcaligner.rocksdb_custom.BlobPathSeq) = .empty;
            errdefer blob_path_seqs.deinit(scratch_allocator);
            const iter = c.rocksdb_create_iterator_cf(
                storage.db,
                prefix_scan_roptions,
                storage.cfs.get(.b_pi2bpi),
            ).?;
            defer c.rocksdb_iter_destroy(iter);
            c.rocksdb_iter_seek(iter, @ptrCast(&blob_hash), @sizeOf(c.git_oid));
            while (c.rocksdb_iter_valid(iter) != 0) : (c.rocksdb_iter_next(iter)) {
                const repo_path_seq: vcaligner.rocksdb_custom.PathSeq = blk: {
                    var klen: usize = undefined;
                    const key_ptr = c.rocksdb_iter_key(iter, &klen);
                    const blob_path_key = std.mem.bytesAsValue(vcaligner.rocksdb_custom.BlobPathKey, key_ptr[0..klen]);
                    std.debug.assert(blob_path_key.blob_hash == blob_hash);
                    break :blk blob_path_key.path_seq;
                };
                const blob_path_seq: vcaligner.rocksdb_custom.BlobPathSeq = blk: {
                    var vlen: usize = undefined;
                    const value_ptr = c.rocksdb_iter_value(iter, &vlen);
                    break :blk std.mem.bytesToValue(vcaligner.rocksdb_custom.BlobPathSeq, value_ptr[0..vlen]);
                };
                try repo_path_seqs.append(result_allocator, repo_path_seq);
                try blob_path_seqs.append(scratch_allocator, blob_path_seq);
            }
            break :repo_path_seqs .{
                try repo_path_seqs.toOwnedSlice(result_allocator),
                blob_path_seqs,
            };
        };
        errdefer result_allocator.free(repo_path_seqs);
        defer blob_path_seqs.deinit(scratch_allocator);
        const len = repo_path_seqs.len;
        std.debug.assert(len == blob_path_seqs.items.len);
        var commit_collections_per_repo_path: std.ArrayListUnmanaged(vcaligner.commit_range.CommitCollection) = try .initCapacity(result_allocator, len);
        errdefer {
            for (commit_collections_per_repo_path.items) |commit_collection| {
                commit_collection.deinit(result_allocator);
            }
            commit_collections_per_repo_path.deinit(result_allocator);
        }
        const iter = c.rocksdb_create_iterator_cf(
            storage.db,
            prefix_scan_roptions,
            storage.cfs.get(.bpi_ci),
        ).?;
        defer c.rocksdb_iter_destroy(iter);
        for (blob_path_seqs.items) |blob_path_seq| {
            const commit_collection = commit_collection: {
                var builder: vcaligner.commit_range.CommitCollection.Builder = .init;
                errdefer builder.b.deinit(result_allocator);
                c.rocksdb_iter_seek(iter, @ptrCast(&blob_path_seq), @sizeOf(vcaligner.rocksdb_custom.BlobPathSeq));
                while (c.rocksdb_iter_valid(iter) != 0) : (c.rocksdb_iter_next(iter)) {
                    const ci_native: vcaligner.rocksdb_custom.CommitSeqNative = blk: {
                        var klen: usize = undefined;
                        const key_ptr = c.rocksdb_iter_key(iter, &klen);
                        const key = std.mem.bytesAsValue(vcaligner.rocksdb_custom.Key, key_ptr[0..klen]);
                        std.debug.assert(key.blob_path_seq == blob_path_seq);
                        const ci: vcaligner.rocksdb_custom.CommitSeq = key.commit_seq;
                        break :blk ci.toNative();
                    };
                    try builder.appendAssumeGreaterNative(result_allocator, ci_native);
                }
                break :commit_collection try builder.toOwnedCommitRanges(result_allocator);
            };
            commit_collections_per_repo_path.appendAssumeCapacity(commit_collection);
        }
        break :commit_collections_per_repo_path .{
            repo_path_seqs,
            try commit_collections_per_repo_path.toOwnedSlice(result_allocator),
        };
    };
    errdefer {
        result_allocator.free(repo_path_seqs);
        result_allocator.free(commit_collections_per_repo_path);
    }
    std.debug.assert(commit_collections_per_repo_path.len == repo_path_seqs.len);
    // TODO
    _ = blob_info_out;
}
