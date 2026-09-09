const std = @import("std");
const zargs = @import("zargs");
const vcaligner = @import("vcaligner");
const diag = vcaligner.diag;
const c = vcaligner.c_helper.c;
const AnaRunner = @import("AnaRunner.zig");

pub fn analysis(noalias runconf: *const AnaRunner, gpac: vcaligner.gpa.Concurrent, last_diag: *diag.Diagnostic) !void {
    var gpae_instance: mainWorkerManagedGpa.Instance = .{ .instance = .init() };
    const gpae = gpae_instance.gpa();
    // 仅前半部分需要并行解析的部分需要频繁复用pool，此为其生存期。
    var release_artifact_paths_depot: release_artifact.PathDepot, var blob_agendas: ReleaseArtifactBlobManifest = pool_lifetime: {
        var pool: vcaligner.Pool = undefined;
        try pool.init(.{ .allocator = gpac.allocator, .n_jobs = runconf.n_jobs - 1 });
        defer pool.deinit();
        var release_artifact_paths_depot: release_artifact.PathDepot, var blob_agendas: ReleaseArtifactBlobManifest = collect_artifacts_blob: {
            const paths_depot, var node_depot, var blob_agendas_building = try @import("collect_artifacts_blob.zig").collectArtifactsBlob(
                &pool,
                runconf.release_path,
                gpae,
            );
            errdefer paths_depot.deinit(gpae);
            defer node_depot.deinit(gpae);
            break :collect_artifacts_blob .{ paths_depot, try blob_agendas_building.toBlobAgendas(gpae, &node_depot) };
        };
        blob_topology: {
            break :blob_topology;
        }
        _ = &release_artifact_paths_depot;
        _ = &blob_agendas;
        break :pool_lifetime .{ release_artifact_paths_depot, blob_agendas };
    };
    defer {
        blob_agendas.deinit(gpae);
        release_artifact_paths_depot.deinit(gpae);
    }

    _ = last_diag;
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
    // XXX: 目前暂未考虑Node的常驻遍历。我的意思是，目前我把release path nodes的转换操作弄到BlobAgenda那边了。
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
    entrys: []Entry,
    release_artifact_paths: ReleaseArtifactPathKeysBacking,
    pub fn deinit(self: *ReleaseArtifactBlobManifest, gpa: mainWorkerManagedGpa) void {
        gpa.allocator().free(self.entrys);
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
        pub fn toBlobAgendas(
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
            const agendas = blk: {
                var agenda_list: std.ArrayListUnmanaged(Entry) = .empty;
                errdefer agenda_list.deinit(gpa.allocator());
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
                    try agenda_list.append(gpa.allocator(), .{
                        .blob_hash = current_hash,
                        .release_artifact_paths_slicer = .{
                            .start = i,
                            .len = j - i,
                        },
                    });
                    i = j;
                }
                break :blk try agenda_list.toOwnedSlice(gpa.allocator());
            };
            errdefer gpa.allocator().free(agendas);
            return .{
                .entrys = agendas,
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
        };
        pub fn slicedView(self: ReleaseArtifactPathKeysBacking, slicer: Slicer) SlicedView {
            return .{ .slice = self.backing[slicer.start..][0..slicer.len] };
        }
    };
};
