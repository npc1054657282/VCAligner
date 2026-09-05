const std = @import("std");
const zargs = @import("zargs");
const vcaligner = @import("vcaligner");
const diag = vcaligner.diag;
const c = vcaligner.c_helper.c;
const AnaRunner = @import("AnaRunner.zig");

pub fn analysis(noalias runconf: *const AnaRunner, gpa: vcaligner.gpa.Concurrent, last_diag: *diag.Diagnostic) !void {
    // 仅前半部分需要并行解析的部分需要频繁复用pool，此为其生存期。
    pool_lifetime: {
        var pool: vcaligner.Pool = undefined;
        try pool.init(.{ .allocator = gpa.allocator, .n_jobs = runconf.n_jobs - 1 });
        defer pool.deinit();
        break :pool_lifetime;
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
    pub const Paths = struct {
        arena_state: vcaligner.StArena.State,
        pub const Index = struct {
            path: [:0]const u8,
        };
        pub const PinnedAppending = struct {
            arena: vcaligner.StArena,
            pub fn init(gpa: mainWorkerManagedGpa) PinnedAppending {
                return .{ .arena = .init(gpa.allocator()) };
            }
            pub fn deinit(noalias self: *const PinnedAppending) void {
                return self.arena.deinit();
            }
            pub fn toUnpinned(noalias self: *const PinnedAppending) Paths {
                return .{ .arena_state = self.arena.state };
            }
            pub fn appendDupeZ(self: *PinnedAppending, path: []const u8) !Index {
                return .{ .path = try self.arena.allocator().dupeZ(u8, path) };
            }
            pub fn get(noalias self: *const PinnedAppending, i: Index) [:0]const u8 {
                _ = self;
                return i.path;
            }
        };
        pub fn deinit(noalias self: *const Paths, gpa: mainWorkerManagedGpa) void {
            self.arena_state.promote(gpa.allocator()).deinit();
        }
        pub fn get(noalias self: *const Paths, i: Index) [:0]const u8 {
            _ = self;
            return i.path;
        }
    };
    // XXX: 目前暂未考虑Node的常驻遍历。我的意思是，目前我把release path nodes的转换操作弄到BlobAgenda那边了。
    // 所以这里留了实现空间，如果未来想要Node的常驻遍历，可以在这里再实现一次。
    pub const Node = struct {
        path_i: Paths.Index,
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
                pub fn create(self: *PinnedAppending) !Index {
                    return .{ .node = try self.arena.allocator().create() };
                }
                pub fn get(noalias self: *const PinnedAppending, i: Index) *Node {
                    _ = self;
                    return i.node;
                }
            };
            pub fn deinit(noalias self: *const Depot, gpa: mainWorkerManagedGpa) void {
                self.arena_state.promote(gpa.allocator()).deinit();
            }
            pub fn get(noalias self: *const Depot, i: Index) *const Node {
                _ = self;
                return i.node;
            }
            pub const Index = struct {
                node: *Node,
            };
        };
    };
};

pub const BlobAgenda = struct {
    _: void align(std.atomic.cache_line),
    blob_hash: c.git_oid,
    release_artifact_paths_slicer: ReleaseArtifactPaths.Slicer,
    pub fn deinit(self: *BlobAgenda) void {
        _ = self;
    }
};
pub const BlobAgendas = struct {
    agendas: []BlobAgenda,
    release_artifact_paths: ReleaseArtifactPaths,
    pub const Building = struct {
        list: std.ArrayListUnmanaged(ReleaseArtifactPaths.Unit),
        pub fn deinit(self: *Building, gpa: mainWorkerManagedGpa) void {
            self.list.deinit(gpa.allocator());
        }
        pub fn append(self: *Building, gpa: mainWorkerManagedGpa, ni: release_artifact.Node.Depot.Index) !void {
            return try self.list.append(gpa.allocator(), .{ .node = ni });
        }
        pub fn toBlobAgendas(self: *Building, gpa: mainWorkerManagedGpa) !BlobAgendas {
            const SortContext = struct {
                pub fn lessThan(context: void, a: ReleaseArtifactPaths.Unit, b: ReleaseArtifactPaths.Unit) bool {
                    _ = context;
                    return c.git_oid_cmp(&a.node.node.blob_hash, &b.node.node.blob_hash) < 0;
                }
            };
            std.sort.pdq(ReleaseArtifactPaths.Unit, self.list.items, {}, SortContext.lessThan);
            const agendas = blk: {
                var agenda_list: std.ArrayListUnmanaged(BlobAgenda) = .empty;
                errdefer agenda_list.deinit(gpa.allocator());
                var i: usize = 0;
                while (i < self.list.items.len) {
                    const current_hash = self.list.items[i].node.node.blob_hash;
                    var j = i + 1;
                    while (j < self.list.items.len) : (j += 1) {
                        if (c.git_oid_cmp(&self.list.items[j].node.node.blob_hash, &current_hash) != 0) break;
                    }
                    for (self.list.items[i..j]) |*unit| {
                        const path = unit.node.node.path_i;
                        unit.* = .{ .path = path };
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
                .agendas = agendas,
                .release_artifact_paths = .{ .backing = try self.list.toOwnedSlice(gpa.allocator()) },
            };
        }
    };
    pub fn deinit(self: *BlobAgendas, gpa: mainWorkerManagedGpa) void {
        for (self.agendas) |*agenda| agenda.deinit();
        gpa.allocator().free(self.agendas);
        self.release_artifact_paths.deinit(gpa);
    }
};

pub const ReleaseArtifactPaths = struct {
    backing: []Unit,
    pub const Unit = union {
        node: release_artifact.Node.Depot.Index,
        path: release_artifact.Paths.Index,
    };
    pub fn deinit(self: ReleaseArtifactPaths, gpa: mainWorkerManagedGpa) void {
        gpa.allocator().free(self.backing);
    }
    pub const Slicer = struct {
        start: usize,
        len: usize,
    };
    pub const PathView = struct {
        slice: []const Unit,
        pub fn get(self: PathView, index: usize) release_artifact.Paths.Index {
            return self.slice[index].path;
        }
    };
    pub fn slicedPathView(self: ReleaseArtifactPaths, slicer: Slicer) PathView {
        return .{ .slice = self.backing[slicer.start..][0..slicer.len] };
    }
};
