const std = @import("std");
const vcaligner = @import("vcaligner");
const c = vcaligner.c_helper.c;
const analysis = @import("analysis.zig");

pub const TopologyShapeKind = enum {
    single,
    integer_bitset,
    dynamic_bitset,
    pub fn fromRepoPathSeqsNum(repo_paths_seqs_count: usize) TopologyShapeKind {
        std.debug.assert(repo_paths_seqs_count > 0);
        if (repo_paths_seqs_count == 1) return .single;
        if (repo_paths_seqs_count <= @bitSizeOf(usize)) return .integer_bitset;
        return .dynamic_bitset;
    }
};

pub const BitTopologySetShapeKind: type = vcaligner.sub_enum.SubEnum(TopologyShapeKind, &[_]TopologyShapeKind{
    .integer_bitset,
    .dynamic_bitset,
});

pub fn BitSetTopology(comptime kind: BitTopologySetShapeKind) type {
    return struct {
        pub const Shape = struct {
            raw: switch (kind) {
                .integer_bitset => std.bit_set.IntegerBitSet(@bitSizeOf(usize)),
                .dynamic_bitset => std.bit_set.DynamicBitSetUnmanaged,
            },
            pub fn initEmpty(allocator: std.mem.Allocator, bit_length: usize) !Shape {
                return switch (kind) {
                    .integer_bitset => .{ .raw = .initEmpty() },
                    .dynamic_bitset => .{ .raw = try .initEmpty(allocator, bit_length) },
                };
            }
            pub fn deinit(self: *Shape, allocator: std.mem.Allocator) void {
                switch (kind) {
                    .integer_bitset => {},
                    .dynamic_bitset => self.raw.deinit(allocator),
                }
            }
            pub fn clone(self: *const Shape, new_allocator: std.mem.Allocator) !Shape {
                return switch (kind) {
                    .integer_bitset => .{ .raw = self.raw },
                    .dynamic_bitset => .{ .raw = try self.raw.clone(new_allocator) },
                };
            }
            pub fn unsetAll(self: *Shape) void {
                switch (kind) {
                    .integer_bitset => self.raw = .initEmpty(),
                    .dynamic_bitset => self.raw.unsetAll(),
                }
            }
            pub fn view(self: Shape) View {
                return switch (kind) {
                    .integer_bitset => .{ .raw = self.raw },
                    .dynamic_bitset => .{ .raw = self.raw },
                };
            }
            pub const View = struct {
                raw: switch (kind) {
                    .integer_bitset => std.bit_set.IntegerBitSet(@bitSizeOf(usize)),
                    .dynamic_bitset => std.bit_set.DynamicBitSetUnmanaged,
                },
            };
        };
        pub const Entry = struct {
            shape: Shape,
            commits: vcaligner.commit_range.CommitCollection,
            pub const Building = struct {
                shape: Shape,
                commits: vcaligner.commit_range.CommitCollection.Builder,
            };
        };
    };
}

pub const BlobTopologies = union(TopologyShapeKind) {
    // 只有一个repo path seq。实际上就是`commit_collections_per_repo_path[0].view()`
    single: vcaligner.commit_range.CommitCollection.View,
    integer_bitset: []BitSetTopology(.integer_bitset).Entry,
    dynamic_bitset: []BitSetTopology(.dynamic_bitset).Entry,
};

pub const BlobAnalysisResult = struct {
    _: void align(std.atomic.cache_line),
    analyser_id: usize,
    // 以下堆上内容均通过其所属analyser的result_recycling_arena分配。
    // 发生错误不需要标记哪些需要释放哪些不需要释放，统一由result_recycling_arena集体释放。
    repo_path_seqs: []vcaligner.rocksdb_custom.PathSeq,
    details: union {
        // repo_path_seqs.len == 0
        empty: void,
        // repo_path_seqs.len > 0
        active: struct {
            commit_collections_per_repo_path: [*]vcaligner.commit_range.CommitCollection,
            topologies: BlobTopologiesResolution,
        },
    },
};

pub const BlobTopologiesResolution = union(TopologyDecision) {
    // 不需要tag，因为如果分析了，实际类别与repo_path_seqs的数量挂钩。
    proceed: vcaligner.bare_union.BareUnion(BlobTopologies),
    // 跳过分析，表现形式为把所有repo path seqs的CommitCollection做并集。
    skip: vcaligner.commit_range.CommitCollection,
};

pub fn analyseBlobTopology(
    blob_hash_entries: []const analysis.ReleaseArtifactBlobManifest.Entry,
    pool: *vcaligner.Pool,
    storage: vcaligner.cli.ana_runner.Storage,
    analyser_ctxs: []analysis.SubAnalyserStation,
    gpa: vcaligner.gpa.Concurrent,
) ![]BlobAnalysisResult {
    const results = try gpa.allocator.alloc(BlobAnalysisResult, blob_hash_entries.len);
    errdefer comptime unreachable;
    var wait_group: std.Thread.WaitGroup = .{};
    defer pool.waitAndWork(&wait_group);
    for (results, blob_hash_entries) |*blob_info_out, *blob_hash_entry| {
        pool.spawnWgId(&wait_group, analyseBlobTopologySubTask, .{
            blob_hash_entry.blob_hash,
            blob_info_out,
            storage,
            analyser_ctxs,
            gpa,
        });
    }
    return results;
}

pub fn analyseBlobTopologySubTask(
    thrd_id: usize,
    blob_hash: c.git_oid,
    blob_info_out: *BlobAnalysisResult,
    storage: vcaligner.cli.ana_runner.Storage,
    analyser_ctxs: []analysis.SubAnalyserStation,
    gpa: vcaligner.gpa.Concurrent,
) void {
    analyseBlobTopologySub(
        thrd_id,
        blob_hash,
        blob_info_out,
        storage,
        analyser_ctxs,
        gpa,
    ) catch {
        vcaligner.crash_dump.dumpAndCrash(@src());
    };
}

pub fn analyseBlobTopologySub(
    thrd_id: usize,
    blob_hash: c.git_oid,
    blob_info_out: *BlobAnalysisResult,
    storage: vcaligner.cli.ana_runner.Storage,
    analyser_ctxs: []analysis.SubAnalyserStation,
    gpa: vcaligner.gpa.Concurrent,
) !void {
    var recycling_arena_handle = analyser_ctxs[thrd_id].recycling_arena_state.handle(gpa.allocator);
    const allocator = recycling_arena_handle.allocator();
    const repo_path_seqs, const commit_collections_per_repo_path = commit_collections_per_repo_path: {
        const prefix_scan_roptions = blk: {
            const roptions = c.rocksdb_readoptions_create().?;
            vcaligner.rocksdb_custom.applyPrefixScanToReadOptions(roptions);
            break :blk roptions;
        };
        defer c.rocksdb_readoptions_destroy(prefix_scan_roptions);
        const repo_path_seqs: []vcaligner.rocksdb_custom.PathSeq, var blob_path_seqs: std.ArrayListUnmanaged(vcaligner.rocksdb_custom.BlobPathSeq) = repo_path_seqs: {
            var repo_path_seqs: std.ArrayListUnmanaged(vcaligner.rocksdb_custom.PathSeq) = .empty;
            errdefer repo_path_seqs.deinit(allocator);
            var blob_path_seqs: std.ArrayListUnmanaged(vcaligner.rocksdb_custom.BlobPathSeq) = .empty;
            errdefer blob_path_seqs.deinit(allocator);
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
                    std.debug.assert(std.mem.eql(u8, &blob_path_key.blob_hash.id, &blob_hash.id));
                    break :blk blob_path_key.path_seq;
                };
                const blob_path_seq: vcaligner.rocksdb_custom.BlobPathSeq = blk: {
                    var vlen: usize = undefined;
                    const value_ptr = c.rocksdb_iter_value(iter, &vlen);
                    break :blk std.mem.bytesToValue(vcaligner.rocksdb_custom.BlobPathSeq, value_ptr[0..vlen]);
                };
                try repo_path_seqs.append(allocator, repo_path_seq);
                try blob_path_seqs.append(allocator, blob_path_seq);
            }
            break :repo_path_seqs .{
                try repo_path_seqs.toOwnedSlice(allocator),
                blob_path_seqs,
            };
        };
        errdefer allocator.free(repo_path_seqs);
        if (repo_path_seqs.len == 0) {
            blob_info_out.* = .{
                ._ = {},
                .analyser_id = thrd_id,
                .repo_path_seqs = repo_path_seqs,
                .details = .{ .empty = {} },
            };
            return;
        }
        defer blob_path_seqs.deinit(allocator);
        const len = repo_path_seqs.len;
        std.debug.assert(len == blob_path_seqs.items.len);
        var commit_collections_per_repo_path: std.ArrayListUnmanaged(vcaligner.commit_range.CommitCollection) = try .initCapacity(allocator, len);
        errdefer {
            for (commit_collections_per_repo_path.items) |commit_collection| {
                commit_collection.deinit(allocator);
            }
            commit_collections_per_repo_path.deinit(allocator);
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
                errdefer builder.b.deinit(allocator);
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
                    try builder.appendNativeAssumeGreater(allocator, ci_native);
                }
                break :commit_collection try builder.toOwnedCommitRanges(allocator);
            };
            commit_collections_per_repo_path.appendAssumeCapacity(commit_collection);
        }
        break :commit_collections_per_repo_path .{
            repo_path_seqs,
            try commit_collections_per_repo_path.toOwnedSlice(allocator),
        };
    };
    errdefer {
        allocator.free(repo_path_seqs);
        allocator.free(commit_collections_per_repo_path);
    }
    std.debug.assert(commit_collections_per_repo_path.len == repo_path_seqs.len);

    const topologies: BlobTopologiesResolution = sw: switch (decideTopologyAnalysis(blob_hash)) {
        .proceed => topologyAnalysisAndThenDecideTopologyUsage(commit_collections_per_repo_path, allocator) catch |err| switch (err) {
            TopologyDecision.Error.DecideSkipUseTopologies => continue :sw .skip,
            else => return err,
        },
        .skip => .{ .skip = try vcaligner.commit_range.unionCollections(allocator, commit_collections_per_repo_path) },
    };
    analyser_ctxs[thrd_id].agenda_unit_count_statistics += switch (topologies) {
        .skip => 1,
        .proceed => switch (TopologyShapeKind.fromRepoPathSeqsNum(repo_path_seqs.len)) {
            .single => 1,
            .integer_bitset => topologies.proceed.integer_bitset.len,
            .dynamic_bitset => topologies.proceed.dynamic_bitset.len,
        },
    };
    blob_info_out.* = .{
        ._ = {},
        .analyser_id = thrd_id,
        .repo_path_seqs = repo_path_seqs,
        .details = .{ .active = .{
            .commit_collections_per_repo_path = commit_collections_per_repo_path.ptr,
            .topologies = topologies,
        } },
    };
}

fn topologyAnalysisAndThenDecideTopologyUsage(
    commit_collections_per_repo_path: []const vcaligner.commit_range.CommitCollection,
    allocator: std.mem.Allocator,
) !BlobTopologiesResolution {
    const proceed = try topologyAnalysis(commit_collections_per_repo_path, allocator);
    errdefer switch (proceed) {
        inline .integer_bitset, .dynamic_bitset => |entries| {
            for (entries) |*entry| {
                entry.shape.deinit(allocator);
                entry.commits.deinit(allocator);
            }
            allocator.free(entries);
        },
        .single => {},
    };
    switch (decideTopologyUsage(proceed)) {
        .proceed => return .{ .proceed = vcaligner.bare_union.taggedToBare(proceed) },
        .skip => return TopologyDecision.Error.DecideSkipUseTopologies,
    }
}

fn topologyAnalysis(
    commit_collections_per_repo_path: []const vcaligner.commit_range.CommitCollection,
    allocator: std.mem.Allocator,
) !BlobTopologies {
    std.debug.assert(commit_collections_per_repo_path.len > 0);
    const kind: TopologyShapeKind = .fromRepoPathSeqsNum(commit_collections_per_repo_path.len);
    switch (kind) {
        .single => return .{ .single = commit_collections_per_repo_path[0].view() },
        inline else => |comptime_kind| {
            const bitset_kind: BitTopologySetShapeKind = @enumFromInt(@intFromEnum(comptime_kind));
            const entries = try sweepLine(
                bitset_kind,
                commit_collections_per_repo_path,
                allocator,
            );
            return @unionInit(BlobTopologies, @tagName(comptime_kind), entries);
        },
    }
}

fn sweepLine(
    comptime kind: BitTopologySetShapeKind,
    commit_collections_per_repo_path: []const vcaligner.commit_range.CommitCollection,
    allocator: std.mem.Allocator,
) ![]BitSetTopology(kind).Entry {
    const num_repo_path = commit_collections_per_repo_path.len;
    std.debug.assert(num_repo_path > 0);
    var topologies: std.ArrayListUnmanaged(BitSetTopology(kind).Entry) = .empty;
    errdefer topologies.deinit(allocator);
    var building_topologies: std.ArrayListUnmanaged(BitSetTopology(kind).Entry.Building) = .empty;
    defer building_topologies.deinit(allocator);
    errdefer {
        for (topologies.items) |*entry| {
            entry.shape.deinit(allocator);
            entry.commits.deinit(allocator);
        }
        for (building_topologies.items[topologies.items.len..]) |*building_entry| {
            building_entry.shape.deinit(allocator);
            building_entry.commits.b.deinit(allocator);
        }
    }
    const cursors = try allocator.alloc(usize, num_repo_path);
    @memset(cursors, 0);
    defer allocator.free(cursors);
    var active_repo_paths: BitSetTopology(kind).Shape = try .initEmpty(allocator, num_repo_path);
    defer active_repo_paths.deinit(allocator);
    var repos_triggering_at_min: BitSetTopology(kind).Shape = try .initEmpty(allocator, num_repo_path);
    defer repos_triggering_at_min.deinit(allocator);
    var current_time: vcaligner.rocksdb_custom.CommitSeqNative = 0;
    // 每个range被认为是发送开始事件和结束时间，时间向前跑，不断翻转在range内和不在range内的状态。
    while (true) {
        var maybe_min_event_time: ?vcaligner.rocksdb_custom.CommitSeqNative = null;
        // 扫描寻找最小事件时间
        scan_min_event_time: for (commit_collections_per_repo_path, 0..) |commit_collection, r| {
            if (cursors[r] >= commit_collection.ranges.len) continue :scan_min_event_time;
            const range = commit_collection.ranges[cursors[r]];
            const event_time = if (active_repo_paths.raw.isSet(r)) range.end + 1 else range.start;
            reset_old_state: {
                if (maybe_min_event_time) |min_event_time| {
                    if (event_time > min_event_time) continue :scan_min_event_time;
                    if (event_time == min_event_time) break :reset_old_state;
                }
                maybe_min_event_time = event_time;
                repos_triggering_at_min.unsetAll();
            }
            repos_triggering_at_min.raw.set(r);
        }
        if (maybe_min_event_time) |min_event_time| {
            if (active_repo_paths.raw.count() > 0 and current_time < min_event_time) {
                const valid_range: vcaligner.commit_range.CommitRange = .packStartEnd(current_time, min_event_time);
                try commitToBuildingTopologies(kind, allocator, &building_topologies, &active_repo_paths, valid_range);
            }
            // 状态推进
            var it = repos_triggering_at_min.raw.iterator(.{});
            while (it.next()) |r| {
                active_repo_paths.raw.toggle(r);
                if (!active_repo_paths.raw.isSet(r)) {
                    cursors[r] += 1;
                }
            }
            current_time = min_event_time;
        }
    }
    try topologies.ensureTotalCapacity(allocator, building_topologies.items.len);
    for (building_topologies.items) |*building_entry|
        topologies.appendAssumeCapacity(.{
            .shape = building_entry.shape,
            .commits = try building_entry.commits.toOwnedCommitRanges(allocator),
        });
    return try topologies.toOwnedSlice(allocator);
}

fn commitToBuildingTopologies(
    comptime kind: BitTopologySetShapeKind,
    allocator: std.mem.Allocator,
    building_topologies: *std.ArrayListUnmanaged(BitSetTopology(kind).Entry.Building),
    shape: *const BitSetTopology(kind).Shape,
    valid_range: vcaligner.commit_range.CommitRange,
) !void {
    for (building_topologies.items) |*entry| {
        if (entry.shape.raw.eql(shape.raw)) {
            try entry.commits.appendRangeAssumeGreater(allocator, valid_range);
            break;
        }
    } else {
        var new_entry: BitSetTopology(kind).Entry.Building = .{ .shape = try shape.clone(allocator), .commits = .init };
        errdefer {
            new_entry.shape.deinit(allocator);
            new_entry.commits.b.deinit(allocator);
        }
        try new_entry.commits.appendRangeAssumeGreater(allocator, valid_range);
        try building_topologies.append(allocator, new_entry);
    }
}

pub const TopologyDecision = enum {
    proceed,
    skip,
    pub const Error = error{
        DecideSkipUseTopologies,
    };
};

// 事前过滤，通过看一眼blob hash决定是否分析拓扑
// XXX: 当前的设计是空文件过滤。将来可能允许自定义配置
pub fn decideTopologyAnalysis(
    blob_hash: c.git_oid,
) TopologyDecision {
    if (std.mem.eql(u8, &blob_hash.id, &vcaligner.cli.ana_runner.empty_git_blob_sha1_hash.id)) return .skip;
    return .proceed;
}

// 事后过滤，看了拓扑分析结果决定是否使用拓扑
// XXX: 当前的设计仅考虑拓扑数量，且实际上并不真的投入使用。将来可能允许自定义配置尤其是拓扑数量阈值
pub fn decideTopologyUsage(
    topologies: BlobTopologies,
) TopologyDecision {
    const topologies_num = switch (topologies) {
        .single => 1,
        .integer_bitset => |t| t.len,
        .dynamic_bitset => |t| t.len,
    };
    _ = topologies_num;
    return .proceed;
}
