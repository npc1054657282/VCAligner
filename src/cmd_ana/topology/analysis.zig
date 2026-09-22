const std = @import("std");
const zargs = @import("zargs");
const vcaligner = @import("vcaligner");
const diag = vcaligner.diag;
const c = vcaligner.c_helper.c;
const AnaRunner = @import("AnaRunner.zig");
const analyse_blob_topology = @import("analyse_blob_topology.zig");
const analyse_candidates = @import("analyse_candidates.zig");

pub const SubAnalyserStation = struct {
    _: void align(std.atomic.cache_line),
    recycling_arena_state: vcaligner.ExclusiveRecyclingArena(0).State,
    agenda_unit_count_statistics: usize,
};

pub const SubAnalysersHub = struct {
    stations: []SubAnalyserStation,
    pub fn init(n_jobs: usize, gpa: vcaligner.gpa.Concurrent) !SubAnalysersHub {
        const stations = try gpa.allocator.alloc(SubAnalyserStation, n_jobs);
        errdefer gpa.allocator.free(stations);
        @memset(stations, .{ ._ = {}, .recycling_arena_state = .{}, .agenda_unit_count_statistics = 0 });
        return .{ .stations = stations };
    }
    pub fn deinit(self: SubAnalysersHub, gpa: vcaligner.gpa.Concurrent) void {
        for (self.stations) |*station| {
            const handle = station.recycling_arena_state.handle(gpa.allocator);
            handle.deinit();
        }
        gpa.allocator.free(self.stations);
    }
};

pub fn analysis(noalias runconf: *const AnaRunner, gpac: vcaligner.gpa.Concurrent, last_diag: *diag.Diagnostic) !void {
    var gpae_instance: mainWorkerManagedGpa.Instance = .{ .instance = .init() };
    const gpae = gpae_instance.gpa();
    // 仅前半部分需要并行解析的部分需要频繁复用pool，此为其生存期。
    const release_artifact_paths_depot: release_artifact.PathDepot, const blob_manifest: ReleaseArtifactBlobManifest, const blob_analyser_hub: SubAnalysersHub, const blob_analysis_results: []analyse_blob_topology.BlobAnalysisResult, const storage: vcaligner.cli.ana_runner.Storage = pool_lifetime: {
        var pool: vcaligner.Pool = undefined;
        try pool.init(.{ .allocator = gpac.allocator, .n_jobs = runconf.n_jobs - 1, .track_ids = true });
        defer pool.deinit();
        const release_artifact_paths_depot: release_artifact.PathDepot, const blob_manifest: ReleaseArtifactBlobManifest = collect_artifacts_blob: {
            const paths_depot, var node_depot, var blob_manifest_building = try @import("collect_artifacts_blob.zig").collectArtifactsBlob(
                &pool,
                runconf.release_path,
                gpae,
            );
            errdefer paths_depot.deinit(gpae);
            defer node_depot.deinit(gpae);
            break :collect_artifacts_blob .{ paths_depot, try blob_manifest_building.toBlobManifest(gpae, &node_depot) };
        };
        errdefer {
            release_artifact_paths_depot.deinit(gpae);
            blob_manifest.deinit(gpae);
        }
        const blob_analyser_hub: SubAnalysersHub = try .init(runconf.n_jobs, gpac);
        errdefer blob_analyser_hub.deinit(gpac);
        const storage: vcaligner.cli.ana_runner.Storage = try .init(runconf.point_lookup_cache_mb, runconf.rocksdb_path, last_diag);
        errdefer storage.deinit();
        const blob_analysis_results: []analyse_blob_topology.BlobAnalysisResult = try analyse_blob_topology.analyseBlobTopology(
            blob_manifest.entries,
            &pool,
            storage,
            blob_analyser_hub.stations,
            gpac,
        );
        errdefer comptime unreachable;
        break :pool_lifetime .{
            release_artifact_paths_depot,
            blob_manifest,
            blob_analyser_hub,
            blob_analysis_results,
            storage,
        };
    };
    defer {
        // 各结果内容由blob_analyser_hub里的可回收arena一并释放，无需分别释放。
        storage.deinit();
        gpac.allocator.free(blob_analysis_results);
        blob_analyser_hub.deinit(gpac);
        blob_manifest.deinit(gpae);
        release_artifact_paths_depot.deinit(gpae);
    }
    // 主线程归并分析所有的分析结果，构造解析单元
    const agendas = merge_agenda_units: {
        const agenda_unit_count = blk: {
            var count: usize = 0;
            for (blob_analyser_hub.stations) |*station| count += station.agenda_unit_count_statistics;
            break :blk count;
        };
        var agendas: std.ArrayListUnmanaged(AgendaUnit) = try .initCapacity(gpac.allocator, agenda_unit_count);
        errdefer agendas.deinit(gpac.allocator);
        for (blob_analysis_results, 0..) |*blob_analysis_result, artifact_blob_id| {
            const repo_path_seqs_count = blob_analysis_result.repo_path_seqs.len;
            if (repo_path_seqs_count == 0) continue;
            switch (blob_analysis_result.details.active.topologies) {
                .skip => |*commit_collection| agendas.appendAssumeCapacity(.{
                    .artifact_blob_id = artifact_blob_id,
                    .maybe_topology_shape = null,
                    .commit_collection = commit_collection.view(),
                    .commit_count = commit_collection.view().commitCount(),
                }),
                .proceed => |*topologies| {
                    const kind: analyse_blob_topology.TopologyShapeKind = .fromRepoPathSeqsNum(repo_path_seqs_count);
                    switch (kind) {
                        .single => agendas.appendAssumeCapacity(.{
                            .artifact_blob_id = artifact_blob_id,
                            .maybe_topology_shape = .single,
                            .commit_collection = topologies.single,
                            .commit_count = topologies.single.commitCount(),
                        }),
                        inline .integer_bitset, .dynamic_bitset => |comptime_kind| {
                            const entries = @field(topologies, @tagName(comptime_kind));
                            for (entries) |*entry| {
                                const commit_collection = entry.commits.view();
                                agendas.appendAssumeCapacity(.{
                                    .artifact_blob_id = artifact_blob_id,
                                    .maybe_topology_shape = @unionInit(AgendaUnit.Shape, @tagName(comptime_kind), entry.shape.view()),
                                    .commit_collection = commit_collection,
                                    .commit_count = commit_collection.commitCount(),
                                });
                            }
                        },
                    }
                },
            }
        }
        break :merge_agenda_units try agendas.toOwnedSlice(gpac.allocator);
    };
    defer gpac.allocator.free(agendas);
    std.sort.pdq(AgendaUnit, agendas, {}, struct {
        fn lessThan(_: void, a: AgendaUnit, b: AgendaUnit) bool {
            const a_has_shape = a.maybe_topology_shape != null;
            const b_has_shape = b.maybe_topology_shape != null;
            if (a_has_shape != b_has_shape) {
                return a_has_shape;
            }
            if (a.commit_count != b.commit_count) {
                return a.commit_count < b.commit_count;
            }
            return a.artifact_blob_id < b.artifact_blob_id;
        }
    }.lessThan);
    const candidate_set = try @import("analyse_candidates.zig").analyseCandidates(agendas, gpae.allocator());
    defer candidate_set.deinit(gpae.allocator());
    try @import("report.zig").report(&runconf.report_output, candidate_set.candidates, storage, agendas, &blob_manifest, blob_analysis_results, &release_artifact_paths_depot, gpae, last_diag);
}

pub const mainWorkerManagedGpa = struct {
    gpa: vcaligner.gpa.Exclusive,
    pub fn allocator(self: mainWorkerManagedGpa) std.mem.Allocator {
        return self.gpa.allocator;
    }
    pub const Instance = struct {
        instance: vcaligner.gpa.Exclusive.Instance,
        pub fn gpa(self: *Instance) mainWorkerManagedGpa {
            return .{ .gpa = self.instance.gpae() };
        }
    };
};

pub const release_artifact = struct {
    pub const Kind = enum { file, sym_link };
    pub const PathDepot = struct {
        arena_state: vcaligner.StArena.State,
        pub const Key = struct {
            raw: [:0]const u8,
        };
        pub const PinnedAppending = struct {
            arena: vcaligner.StArena,
            pub fn init(gpa: mainWorkerManagedGpa) PinnedAppending {
                return .{ .arena = .init(gpa.allocator()) };
            }
            pub fn deinit(noalias self: *const PinnedAppending) void {
                return self.arena.deinit();
            }
            pub fn toUnpinned(noalias self: *const PinnedAppending) PathDepot {
                return .{ .arena_state = self.arena.state };
            }
            pub fn appendDupeZ(self: *PinnedAppending, path: []const u8) !Key {
                return .{ .raw = try self.arena.allocator().dupeZ(u8, path) };
            }
            pub fn get(noalias self: *const PinnedAppending, i: Key) [:0]const u8 {
                _ = self;
                return i.raw;
            }
        };
        pub fn deinit(noalias self: *const PathDepot, gpa: mainWorkerManagedGpa) void {
            self.arena_state.promote(gpa.allocator()).deinit();
        }
        pub fn get(noalias self: *const PathDepot, i: Key) [:0]const u8 {
            _ = self;
            return i.raw;
        }
    };
    // XXX: 目前暂未考虑Node的常驻遍历。我的意思是，目前我把release path nodes的转换操作弄到BlobManifest那边了。
    // 所以这里留了实现空间，如果未来想要Node的常驻遍历，可以在这里再实现一次。
    pub const Node = struct {
        path_key: PathDepot.Key,
        blob_hash: c.git_oid,
        pub const Depot = struct {
            arena_state: vcaligner.StArena.State,
            pub const PinnedAppending = struct {
                arena: vcaligner.StArena,
                pub fn init(gpa: mainWorkerManagedGpa) PinnedAppending {
                    return .{ .arena = .init(gpa.allocator()) };
                }
                pub fn deinit(noalias self: *const PinnedAppending) void {
                    self.arena.deinit();
                }
                pub fn toUnpinned(noalias self: *const PinnedAppending) Depot {
                    return .{ .arena_state = self.arena.state };
                }
                pub fn create(self: *PinnedAppending) !Key {
                    return .{ .raw = try self.arena.allocator().create(Node) };
                }
                pub fn get(noalias self: *const PinnedAppending, i: Key) *Node {
                    _ = self;
                    return i.raw;
                }
            };
            pub fn deinit(noalias self: *const Depot, gpa: mainWorkerManagedGpa) void {
                self.arena_state.promote(gpa.allocator()).deinit();
            }
            pub fn get(noalias self: *const Depot, i: Key) *const Node {
                _ = self;
                return i.raw;
            }
            pub const Key = struct {
                raw: *Node,
            };
        };
    };
};

pub const ReleaseArtifactBlobManifest = struct {
    entries: []Entry,
    release_artifact_paths: ReleaseArtifactPathKeysBacking,
    pub fn deinit(self: ReleaseArtifactBlobManifest, gpa: mainWorkerManagedGpa) void {
        gpa.allocator().free(self.entries);
        self.release_artifact_paths.deinit(gpa);
    }
    pub const Entry = struct {
        blob_hash: c.git_oid,
        release_artifact_paths_slicer: ReleaseArtifactPathKeysBacking.Slicer,
    };
    pub const Building = struct {
        list: std.ArrayListUnmanaged(ReleaseArtifactPathKeysBacking.Unit),
        pub fn deinit(self: *Building, gpa: mainWorkerManagedGpa) void {
            self.list.deinit(gpa.allocator());
        }
        pub fn append(self: *Building, gpa: mainWorkerManagedGpa, ni: release_artifact.Node.Depot.Key) !void {
            return try self.list.append(gpa.allocator(), .{ .nk = ni });
        }
        pub fn toBlobManifest(
            self: *Building,
            gpa: mainWorkerManagedGpa,
            node_depot: *const release_artifact.Node.Depot,
        ) !ReleaseArtifactBlobManifest {
            const SortContext = struct {
                node_depot: *const release_artifact.Node.Depot,
                pub fn lessThan(context: @This(), a: ReleaseArtifactPathKeysBacking.Unit, b: ReleaseArtifactPathKeysBacking.Unit) bool {
                    return c.git_oid_cmp(&context.node_depot.get(a.nk).blob_hash, &context.node_depot.get(b.nk).blob_hash) < 0;
                }
            };
            std.sort.pdq(ReleaseArtifactPathKeysBacking.Unit, self.list.items, @as(SortContext, .{ .node_depot = node_depot }), SortContext.lessThan);
            const entries = blk: {
                var entry_list: std.ArrayListUnmanaged(Entry) = .empty;
                errdefer entry_list.deinit(gpa.allocator());
                var i: usize = 0;
                while (i < self.list.items.len) {
                    const current_hash = node_depot.get(self.list.items[i].nk).blob_hash;
                    var j = i + 1;
                    while (j < self.list.items.len) : (j += 1) {
                        if (c.git_oid_cmp(&node_depot.get(self.list.items[j].nk).blob_hash, &current_hash) != 0) break;
                    }
                    for (self.list.items[i..j]) |*unit| {
                        const pi = node_depot.get(unit.nk).path_key;
                        unit.* = .{ .pk = pi };
                    }
                    try entry_list.append(gpa.allocator(), .{
                        .blob_hash = current_hash,
                        .release_artifact_paths_slicer = .{
                            .start = i,
                            .len = j - i,
                        },
                    });
                    i = j;
                }
                break :blk try entry_list.toOwnedSlice(gpa.allocator());
            };
            errdefer gpa.allocator().free(entries);
            return .{
                .entries = entries,
                .release_artifact_paths = .{ .backing = try self.list.toOwnedSlice(gpa.allocator()) },
            };
        }
    };
    pub const ReleaseArtifactPathKeysBacking = struct {
        backing: []Unit,
        pub const Unit = union {
            nk: release_artifact.Node.Depot.Key,
            pk: release_artifact.PathDepot.Key,
        };
        pub fn deinit(self: ReleaseArtifactPathKeysBacking, gpa: mainWorkerManagedGpa) void {
            gpa.allocator().free(self.backing);
        }
        pub const Slicer = struct {
            start: usize,
            len: usize,
        };
        pub const SlicedView = struct {
            slice: []const Unit,
            pub fn get(self: SlicedView, index: usize) release_artifact.PathDepot.Key {
                return self.slice[index].pk;
            }
            pub fn iter(
                self: SlicedView,
                path_depot: *const release_artifact.PathDepot,
            ) Iter {
                return .{
                    .view = self,
                    .current = 0,
                    .path_depot = path_depot,
                };
            }
            pub const Iter = struct {
                view: SlicedView,
                current: usize,
                path_depot: *const release_artifact.PathDepot,
                pub fn next(self: *Iter) ?[:0]const u8 {
                    const to_yield_index = self.current;
                    if (to_yield_index > self.view.slice.len) unreachable;
                    if (to_yield_index == self.view.slice.len) return null;
                    const to_yield = self.path_depot.get(self.view.get(to_yield_index));
                    self.current += 1;
                    return to_yield;
                }
            };
        };
        pub fn slicedView(self: ReleaseArtifactPathKeysBacking, slicer: Slicer) SlicedView {
            return .{ .slice = self.backing[slicer.start..][0..slicer.len] };
        }
    };
};

pub const AgendaUnit = struct {
    artifact_blob_id: usize,
    maybe_topology_shape: ?Shape,
    commit_collection: vcaligner.commit_range.CommitCollection.View,
    commit_count: usize,
    pub const Shape = union(analyse_blob_topology.TopologyShapeKind) {
        single: void,
        integer_bitset: analyse_blob_topology.BitSetTopology(.integer_bitset).Shape.View,
        dynamic_bitset: analyse_blob_topology.BitSetTopology(.dynamic_bitset).Shape.View,
    };
};
