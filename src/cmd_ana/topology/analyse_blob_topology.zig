const std = @import("std");
const vcaligner = @import("vcaligner");
const c = vcaligner.c_helper.c;
const analysis = @import("analysis.zig");

pub const TopologyShapeKind = enum {
    integer_bitset,
    dynamic_bitset,
};

pub fn TopologyEntry(comptime kind: TopologyShapeKind) type {
    return struct {
        shape: Shape,
        commits: vcaligner.commit_range.CommitCollection,
        pub const Shape: type = switch (kind) {
            .integer_bitset => std.bit_set.IntegerBitSet(@bitSizeOf(usize)),
            .dynamic_bitset => std.bit_set.DynamicBitSetUnmanaged,
        };
        pub fn shapeClone(shape: *const Shape, allocator: std.mem.Allocator) !Shape {
            return switch (kind) {
                .integer_bitset => shape.*,
                .dynamic_bitset => shape.clone(allocator),
            };
        }
        pub fn shapeInitEmpty(allocator: std.mem.Allocator, bit_length: usize) !Shape {
            return switch (kind) {
                .integer_bitset => .initEmpty(),
                .dynamic_bitset => try std.bit_set.DynamicBitSetUnmanaged.initEmpty(allocator, bit_length),
            };
        }
        pub fn shapeDeinit(shape: *Shape, allocator: std.mem.Allocator) void {
            switch (kind) {
                .integer_bitset => {},
                .dynamic_bitset => shape.deinit(allocator),
            }
        }
        pub fn shapeUnsetAll(shape: *Shape) void {
            switch (kind) {
                .integer_bitset => shape.* = .initEmpty(),
                .dynamic_bitset => shape.unsetAll(),
            }
        }
    };
}

pub const Topologies = union(enum) {
    // 没有repo path seq
    none: void,
    // 只有一个repo path seq。实际上就是`commit_collections_per_repo_path[0].view()`
    single: vcaligner.commit_range.CommitCollection.View,
    integer_bitset: []TopologyEntry(.integer_bitset),
    dynamic_bitset: []TopologyEntry(.dynamic_bitset),
};

pub const PerBlobAnalysed = struct {
    _: void align(std.atomic.cache_line),
    analyser_id: usize,
    // 以下堆上内容均通过其所属analyser的result_recycling_arena分配。
    // 发生错误不需要标记哪些需要释放哪些不需要释放，统一由result_recycling_arena集体释放。
    repo_path_seqs: []vcaligner.rocksdb_custom.PathSeq,
    commit_collections_per_repo_path: [*]vcaligner.commit_range.CommitCollection,
    topologies: union(TopologyDecision) {
        // 不需要tag，因为如果分析了，实际类别与repo_path_seqs的数量挂钩。
        proceed: vcaligner.BareUnion(Topologies),
        // 跳过分析，表现形式为把所有repo path seqs的CommitCollection做并集。
        skip: vcaligner.commit_range.CommitCollection,
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

    const topologies: @FieldType(PerBlobAnalysed, "topologies") = switch (decideTopologyAnalysis(blob_hash)) {
        .proceed => {},
        .skip => {
            // TODO: 对所有commit collection做并集运算。
        },
    };
    _ = topologies;
    _ = blob_info_out;
}

fn topologyAnalysis(
    commit_collections_per_repo_path: []const vcaligner.commit_range.CommitCollection,
) vcaligner.BareUnion(Topologies) {
    if (commit_collections_per_repo_path.len == 0) return .none;
    if (commit_collections_per_repo_path.len == 1) return .{ .single = commit_collections_per_repo_path[0].view() };
    if (commit_collections_per_repo_path.len < @bitSizeOf(usize)) {}
}

fn sweepLineFast(
    comptime kind: TopologyShapeKind,
    commit_collections_per_repo_path: []const vcaligner.commit_range.CommitCollection,
    allocator: std.mem.Allocator,
) []TopologyEntry(kind) {
    const num_repo_path = commit_collections_per_repo_path.len;
    std.debug.assert(num_repo_path > 0);
    var topologies: std.ArrayListUnmanaged(TopologyEntry(kind)) = .empty;
    errdefer topologies.deinit(allocator);
    const cursors = try allocator.alloc(usize, num_repo_path);
    @memset(cursors, 0);
    defer allocator.free(cursors);
    var active_repo_paths: TopologyEntry(kind).Shape = try TopologyEntry(kind).shapeInitEmpty(allocator, num_repo_path);
    defer TopologyEntry(kind).shapeDeinit(active_repo_paths, allocator);
    var repos_triggering_at_min: TopologyEntry(kind).Shape = try TopologyEntry(kind).shapeInitEmpty(allocator, num_repo_path);
    defer TopologyEntry(kind).shapeDeinit(repos_triggering_at_min, allocator);
    var current_time: vcaligner.rocksdb_custom.CommitSeqNative = 0;
    // 每个range被认为是发送开始事件和结束时间，时间向前跑，不断翻转在range内和不在range内的状态。
    while (true) {
        var maybe_min_event_time: ?vcaligner.rocksdb_custom.CommitSeqNative = null;
        // 扫描寻找最小事件时间
        scan_min_event_time: for (commit_collections_per_repo_path, 0..) |commit_collection, r| {
            if (cursors[r] >= commit_collection.ranges.len) continue :scan_min_event_time;
            const range = commit_collection.ranges[cursors[r]];
            const event_time = if (active_repo_paths.isSet(r)) range.end + 1 else range.start;
            reset_old_state: {
                if (maybe_min_event_time) |min_event_time| {
                    if (event_time > min_event_time) continue :scan_min_event_time;
                    if (event_time == min_event_time) break :reset_old_state;
                }
                maybe_min_event_time = event_time;
                TopologyEntry(kind).shapeUnsetAll(repos_triggering_at_min);
            }
            repos_triggering_at_min.set(r);
        }
        if (maybe_min_event_time) |min_event_time| {
            if (active_repo_paths.count() > 0 and current_time < min_event_time) {
                const valid_range: vcaligner.commit_range.CommitRange = .packStartEnd(current_time, min_event_time);
                try commitToTopology(kind, allocator, &topologies, &active_repo_paths, valid_range);
            }
            // 状态推进
            var it = repos_triggering_at_min.iterator(.{});
            while (it.next()) |r| {
                active_repo_paths.toggle(r);
                if (!active_repo_paths.isSet(r)) {
                    cursors[r] += 1;
                }
            }
            current_time = min_event_time;
        }
    }
}

fn commitToTopology(
    comptime kind: TopologyShapeKind,
    allocator: std.mem.Allocator,
    topologies: *std.ArrayListUnmanaged(TopologyEntry(kind)),
    shape: *const TopologyEntry(kind).Shape,
    valid_range: vcaligner.commit_range.CommitRange,
) !void {
    _ = allocator;
    _ = topologies;
    _ = shape;
    _ = valid_range;
}

pub const TopologyDecision = enum {
    proceed,
    skip,
};

// 事前过滤，通过看一眼blob hash决定是否分析拓扑
// XXX: 当前的设计是空文件过滤。将来可能允许自定义配置
pub fn decideTopologyAnalysis(
    blob_hash: c.git_oid,
) TopologyDecision {
    if (blob_hash == vcaligner.cli.ana_runner.empty_git_blob_sha1_hash) return .skip;
    return .proceed;
}

// 事后过滤，看了拓扑分析结果决定是否使用拓扑
// XXX: 当前的设计仅考虑拓扑数量，且实际上并不真的投入使用。将来可能允许自定义配置尤其是拓扑数量阈值
pub fn decideTopologyUsage(
    topologies: Topologies,
) TopologyDecision {
    const topologies_num = switch (topologies) {
        .none, .single => return .proceed,
        .integer_bitset => |t| t.shapes.len,
        .dynamic_bitset => |t| t.shapes.len,
    };
    _ = topologies_num;
    return .proceed;
}
