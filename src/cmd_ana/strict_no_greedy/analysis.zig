const std = @import("std");
const vcaligner = @import("vcaligner");
const c = vcaligner.c_helper.c;
const AnaRunner = @import("AnaRunner.zig");
const topology_analysis = @import("../topology/analysis.zig");
const collect_artifacts_blob = @import("../topology/collect_artifacts_blob.zig");
const analyse_candidates = @import("analyse_candidates.zig");
const Storage = vcaligner.cli.ana_runner.Storage;
const PathSeq = vcaligner.rocksdb_custom.PathSeq;
const BlobPathSeq = vcaligner.rocksdb_custom.BlobPathSeq;
const BlobPathKey = vcaligner.rocksdb_custom.BlobPathKey;
const CommitCollection = vcaligner.commit_interval.CommitCollection;

pub const ReleaseFile = struct {
    path: [:0]const u8,
    kind: topology_analysis.release_artifact.Kind,
    blob_hash: c.git_oid,
    state: union(enum) {
        path_phantom,
        blob_phantom: PathSeq,
        matched: struct {
            // CommitCollection的内存由所属worker Arena持有。
            commit_collection: CommitCollection,
            // 证据排序完成后由主线程回填。
            evidence_idx: usize,
        },
    },
};

pub const Evidence = struct {
    release_file_idx: usize,
    commit_collection: CommitCollection,
    commit_count: usize,
    discriminative: bool,
};

pub const SignatureUnit = struct {
    commit_collection: CommitCollection.View,
};

// 与 Topology.SubAnalysersHub 相同的线程局部结果 Arena；
// Diagnostics 仿照 Prep.ParsersHub.SubParser，每个 worker 独立持有。
const SubCollectorStation = struct {
    _: void align(std.atomic.cache_line),
    recycling_arena_state: vcaligner.ExclusiveRecyclingArena(0).State,
    diagnostics: vcaligner.diag.Diagnostics,
    fn deinit(self: *SubCollectorStation, gpac: vcaligner.gpa.Concurrent) void {
        self.diagnostics.arena.deinit();
        const handle = self.recycling_arena_state.handle(gpac.allocator);
        handle.deinit();
    }
};

const SubCollectorsHub = struct {
    stations: []SubCollectorStation,

    fn init(n_jobs: usize, gpac: vcaligner.gpa.Concurrent) !SubCollectorsHub {
        const stations = try gpac.allocator.alloc(SubCollectorStation, n_jobs);
        for (stations) |*station| {
            station.* = .{
                ._ = {},
                .recycling_arena_state = .{},
                .diagnostics = .{
                    .arena = .init(gpac.allocator),
                    .last_diagnostic = undefined,
                    .error_stack = .empty,
                    .double_error = null,
                },
            };
        }
        return .{ .stations = stations };
    }

    fn deinit(self: SubCollectorsHub, gpac: vcaligner.gpa.Concurrent) void {
        for (self.stations) |*station| station.deinit(gpac);
        gpac.allocator.free(self.stations);
    }
};

pub fn relativeRepoPath(repo_path: []const u8, package_directory: ?[:0]const u8) ?[]const u8 {
    if (package_directory) |directory| {
        if (repo_path.len <= directory.len or !std.mem.startsWith(u8, repo_path, directory)) return null;
        if (repo_path[directory.len] != '/') return null;
        return repo_path[directory.len + 1 ..];
    }
    return repo_path;
}

pub fn isDiscriminative(blob: c.git_oid) bool {
    const hashes = vcaligner.cli.ana_runner;
    return !std.mem.eql(u8, &blob.id, &hashes.empty_git_blob_sha1_hash.id) and
        !std.mem.eql(u8, &blob.id, &hashes.lf_git_blob_sha1_hash.id) and
        !std.mem.eql(u8, &blob.id, &hashes.crlf_git_blob_sha1_hash.id);
}

pub fn analysis(runconf: *const AnaRunner, gpac: vcaligner.gpa.Concurrent, last_diag: *vcaligner.diag.Diagnostic) !void {
    var local_gpa_instance: vcaligner.gpa.Exclusive.Instance = .init();
    defer local_gpa_instance.deinit();
    const gpae = local_gpa_instance.gpae();
    const allocator = gpae.allocator;

    var release_path_arena: vcaligner.StArena = .init(allocator);
    defer release_path_arena.deinit();
    var release_files: std.ArrayListUnmanaged(ReleaseFile) = .empty;
    defer release_files.deinit(allocator);
    var release_by_path: std.StringHashMapUnmanaged(usize) = .empty;
    defer release_by_path.deinit(allocator);

    var release_dir = try std.fs.cwd().openDirZ(runconf.release_path, .{ .iterate = true });
    defer release_dir.close();
    try collectReleasePaths(release_dir, release_path_arena.allocator(), allocator, &release_files, &release_by_path);

    const storage: Storage = try .init(runconf.point_lookup_cache_mb, runconf.rocksdb_path, last_diag);
    defer storage.deinit();
    try associateRepoPaths(storage, runconf.package_directory, &release_by_path, release_files.items, last_diag);

    const collector_hub: SubCollectorsHub = try .init(runconf.n_jobs, gpac);
    // 必须晚于报告析构：evidences 中的 CommitCollection 由 worker Arena 持有。
    defer collector_hub.deinit(gpac);
    var evidences: std.ArrayListUnmanaged(Evidence) = .empty;
    defer evidences.deinit(allocator);

    {
        var pool: vcaligner.Pool = undefined;
        try pool.init(.{ .allocator = gpac.allocator, .n_jobs = runconf.n_jobs - 1, .track_ids = true });
        defer pool.deinit();
        var wait_group: std.Thread.WaitGroup = .{};
        // TODO: 将 Git Blob 哈希任务提取到 Strict 与 Topology 共用的模块。
        for (release_files.items) |*file| {
            if (file.state != .blob_phantom) continue;
            pool.spawnWg(&wait_group, collect_artifacts_blob.subTask, .{
                release_dir, file.path, file.kind, &file.blob_hash,
            });
        }
        pool.waitAndWork(&wait_group);
        try collectEvidences(&pool, storage, release_files.items, collector_hub.stations, gpac, &evidences, allocator);
    }

    const SortContext = struct {
        files: []const ReleaseFile,
        fn lessThan(ctx: @This(), a: Evidence, b: Evidence) bool {
            if (a.commit_count != b.commit_count) return a.commit_count < b.commit_count;
            return std.mem.order(u8, ctx.files[a.release_file_idx].path, ctx.files[b.release_file_idx].path) == .lt;
        }
    };
    std.sort.pdq(Evidence, evidences.items, SortContext{ .files = release_files.items }, SortContext.lessThan);
    const signature_units = try allocator.alloc(SignatureUnit, evidences.items.len);
    defer allocator.free(signature_units);
    for (evidences.items, signature_units, 0..) |*evidence, *unit, i| {
        release_files.items[evidence.release_file_idx].state.matched.evidence_idx = i;
        unit.* = .{ .commit_collection = evidence.commit_collection.view() };
    }
    const candidates = try analyse_candidates.analyseCandidates(signature_units, @intCast(evidences.items.len), gpae, 0);
    defer candidates.deinit(allocator, evidences.items.len);
    try @import("report.zig").report(
        &runconf.report_output,
        candidates.candidates,
        evidences.items,
        release_files.items,
        &release_by_path,
        runconf.package_directory,
        storage,
        last_diag,
    );
}

fn collectReleasePaths(
    release_dir: std.fs.Dir,
    path_allocator: std.mem.Allocator,
    allocator: std.mem.Allocator,
    files: *std.ArrayListUnmanaged(ReleaseFile),
    release_by_path: *std.StringHashMapUnmanaged(usize),
) !void {
    var walker = try release_dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        const kind: topology_analysis.release_artifact.Kind = switch (entry.kind) {
            .directory, .whiteout => continue,
            .file => .file,
            .sym_link => .sym_link,
            .block_device, .character_device, .named_pipe => {
                std.log.warn("Abnormal release artifact {s} of kind {s}.", .{ entry.path, @tagName(entry.kind) });
                continue;
            },
            .unix_domain_socket => return error.BadReleasePath,
            .door, .event_port => unreachable,
            .unknown => blk: {
                const stat = try std.posix.fstatatZ(release_dir.fd, entry.path, std.posix.AT.SYMLINK_NOFOLLOW);
                switch (stat.mode & std.posix.S.IFMT) {
                    std.posix.S.IFREG => break :blk .file,
                    std.posix.S.IFLNK => break :blk .sym_link,
                    std.posix.S.IFDIR, std.posix.S.IFCHR, std.posix.S.IFBLK, std.posix.S.IFIFO => continue,
                    else => return error.BadReleasePath,
                }
            },
        };
        const path = try path_allocator.dupeZ(u8, entry.path);
        const idx = files.items.len;
        try files.append(allocator, .{
            .path = path,
            .kind = kind,
            .blob_hash = undefined,
            .state = .path_phantom,
        });
        try release_by_path.put(allocator, path, idx);
    }
}

fn associateRepoPaths(
    storage: Storage,
    package_directory: ?[:0]const u8,
    release_by_path: *const std.StringHashMapUnmanaged(usize),
    files: []ReleaseFile,
    last_diag: *vcaligner.diag.Diagnostic,
) !void {
    const roptions = blk: {
        const roptions = c.rocksdb_readoptions_create().?;
        vcaligner.rocksdb_custom.applyFullScanOfOrderPreservingTypedKeyToReadOptions(roptions, PathSeq);
        break :blk roptions;
    };
    defer c.rocksdb_readoptions_destroy(roptions);
    const iter = c.rocksdb_create_iterator_cf(storage.db, roptions, storage.cfs.get(.pi2p)).?;
    defer c.rocksdb_iter_destroy(iter);
    c.rocksdb_iter_seek_to_first(iter);
    while (c.rocksdb_iter_valid(iter) != 0) : (c.rocksdb_iter_next(iter)) {
        var path_len: usize = undefined;
        const path_ptr = c.rocksdb_iter_value(iter, &path_len);
        const path = relativeRepoPath(path_ptr[0..path_len], package_directory) orelse continue;
        const release_file_idx = release_by_path.get(path) orelse continue;
        var key_len: usize = undefined;
        const key_ptr = c.rocksdb_iter_key(iter, &key_len);
        std.debug.assert(key_len == @sizeOf(PathSeq));
        files[release_file_idx].state = .{
            .blob_phantom = std.mem.bytesToValue(PathSeq, key_ptr[0..key_len]),
        };
    }
    var err_cstr: ?[*:0]u8 = null;
    c.rocksdb_iter_get_error(iter, @ptrCast(&err_cstr));
    try vcaligner.c_helper.checkRocksdbErr(err_cstr, @src(), last_diag);
}

fn collectEvidences(
    pool: *vcaligner.Pool,
    storage: Storage,
    files: []ReleaseFile,
    stations: []SubCollectorStation,
    gpac: vcaligner.gpa.Concurrent,
    evidences: *std.ArrayListUnmanaged(Evidence),
    allocator: std.mem.Allocator,
) !void {
    // Immutable read settings can be shared by all workers. They outlive every
    // Get() and task-local iterator; nothing modifies them after construction.
    const once_get_roptions = c.rocksdb_readoptions_create() orelse return error.OutOfMemory;
    defer c.rocksdb_readoptions_destroy(once_get_roptions);
    c.rocksdb_readoptions_set_fill_cache(once_get_roptions, 0);
    const prefix_scan_roptions = c.rocksdb_readoptions_create() orelse return error.OutOfMemory;
    defer c.rocksdb_readoptions_destroy(prefix_scan_roptions);
    vcaligner.rocksdb_custom.applyPrefixScanToReadOptions(prefix_scan_roptions);

    var wait_group: std.Thread.WaitGroup = .{};
    for (files) |*file| {
        if (file.state != .blob_phantom) continue;
        pool.spawnWgId(&wait_group, collectEvidenceSubTask, .{
            storage, file, stations, gpac, once_get_roptions, prefix_scan_roptions,
        });
    }
    pool.waitAndWork(&wait_group);

    // 子任务仅写自己的 ReleaseFile 槽位。此处串行收集，严格保留原始文件顺序。
    for (files, 0..) |*file, release_file_idx| {
        if (file.state != .matched) continue;
        const collection = file.state.matched.commit_collection;
        try evidences.append(allocator, .{
            .release_file_idx = release_file_idx,
            .commit_collection = collection,
            .commit_count = collection.view().commitCount(),
            .discriminative = isDiscriminative(file.blob_hash),
        });
    }
}

fn collectEvidenceSubTask(
    thrd_id: usize,
    storage: Storage,
    file: *ReleaseFile,
    stations: []SubCollectorStation,
    gpac: vcaligner.gpa.Concurrent,
    once_get_roptions: *c.rocksdb_readoptions_t,
    prefix_scan_roptions: *c.rocksdb_readoptions_t,
) void {
    const station = &stations[thrd_id];
    // 每个 thread id 只会被一个执行流同时使用（含主线程 id 0）。
    collectEvidenceSub(
        storage,
        file,
        station,
        gpac.allocator,
        once_get_roptions,
        prefix_scan_roptions,
    ) catch |err| {
        // 与 Prep.subParseTask 一样，在线程池无法继续传播错误的边界记录诊断后直接终止。
        std.log.err("Strict-No-Greedy evidence collection failed at '{s}'", .{file.path});
        station.diagnostics.log_all(err);
        station.diagnostics.clear();
        vcaligner.crash_dump.dumpAndCrash(@src());
    };
}

fn collectEvidenceSub(
    storage: Storage,
    file: *ReleaseFile,
    station: *SubCollectorStation,
    backing_allocator: std.mem.Allocator,
    once_get_roptions: *c.rocksdb_readoptions_t,
    prefix_scan_roptions: *c.rocksdb_readoptions_t,
) !void {
    const path_seq = file.state.blob_phantom;
    var arena_handle = station.recycling_arena_state.handle(backing_allocator);
    const allocator = arena_handle.allocator();
    const last_diag = &station.diagnostics.last_diagnostic;
    const blob_path_key: BlobPathKey = .{ .blob_hash = file.blob_hash, .path_seq = path_seq };
    var err_cstr: ?[*:0]u8 = null;
    var blob_path_seq_len: usize = undefined;
    const ptr = c.rocksdb_get_cf(
        storage.db,
        once_get_roptions,
        storage.cfs.get(.b_pi2bpi),
        @ptrCast(&blob_path_key),
        @sizeOf(BlobPathKey),
        &blob_path_seq_len,
        @ptrCast(&err_cstr),
    );
    try vcaligner.c_helper.checkRocksdbErr(err_cstr, @src(), last_diag);
    if (ptr == null) return;
    defer c.rocksdb_free(ptr);
    std.debug.assert(blob_path_seq_len == @sizeOf(BlobPathSeq));
    const blob_path_seq = std.mem.bytesToValue(BlobPathSeq, ptr[0..blob_path_seq_len]);

    var builder: CommitCollection.Builder = .init;
    errdefer builder.b.deinit(allocator);
    // XXX: 本用例中迭代器很可能值得每线程复用，[参见](https://github.com/meta/rocksdb/wiki/Iterator)
    // 迭代器复用可以避免每次任务额外创建迭代器的开销，由于启用了块缓存，资源开销不会无限膨胀。
    // 或者，在迭代器复用场景下使用`rocksdb_iter_refresh`刷新缓存，但这不是免费的且可能无必要。
    // 当前实现未采用任何复用措施，保持生命周期简单。迭代器复用是未来可能的优化选项。
    // topology也有类似的可能选择。
    const iter = c.rocksdb_create_iterator_cf(
        storage.db,
        prefix_scan_roptions,
        storage.cfs.get(.bpi_ci),
    ) orelse return error.OutOfMemory;
    defer c.rocksdb_iter_destroy(iter);
    c.rocksdb_iter_seek(iter, @ptrCast(&blob_path_seq), @sizeOf(BlobPathSeq));
    while (c.rocksdb_iter_valid(iter) != 0) : (c.rocksdb_iter_next(iter)) {
        var key_len: usize = undefined;
        const key_ptr = c.rocksdb_iter_key(iter, &key_len);
        std.debug.assert(key_len == @sizeOf(vcaligner.rocksdb_custom.Key));
        const key = std.mem.bytesToValue(vcaligner.rocksdb_custom.Key, key_ptr[0..key_len]);
        if (key.blob_path_seq != blob_path_seq) break;
        try builder.appendNativeAssumeGreater(allocator, key.commit_seq.toNative());
    }
    err_cstr = null;
    c.rocksdb_iter_get_error(iter, @ptrCast(&err_cstr));
    try vcaligner.c_helper.checkRocksdbErr(err_cstr, @src(), last_diag);
    const collection = try builder.toOwnedCommitIntervals(allocator);
    file.state = .{ .matched = .{
        .commit_collection = collection,
        .evidence_idx = undefined,
    } };
}

test "package directory boundary" {
    try std.testing.expectEqualStrings("src/a.py", relativeRepoPath("pkg/src/a.py", "pkg").?);
    try std.testing.expect(relativeRepoPath("pkg2/src/a.py", "pkg") == null);
    try std.testing.expect(relativeRepoPath("pkg", "pkg") == null);
    try std.testing.expectEqualStrings("pkg/src/a.py", relativeRepoPath("pkg/src/a.py", null).?);
}

test "low information exact path evidence" {
    const hashes = vcaligner.cli.ana_runner;
    try std.testing.expect(!isDiscriminative(hashes.empty_git_blob_sha1_hash));
    try std.testing.expect(!isDiscriminative(hashes.lf_git_blob_sha1_hash));
    try std.testing.expect(!isDiscriminative(hashes.crlf_git_blob_sha1_hash));
}
