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
const CommitCollection = vcaligner.commit_range.CommitCollection;

pub const ReleaseFile = struct {
    path: [:0]const u8,
    kind: topology_analysis.release_artifact.Kind,
    repo_path_seq: ?PathSeq = null,
    blob_hash: c.git_oid = undefined,
    status: Status = .path_phantom,
    evidence_idx: ?usize = null,

    pub const Status = enum { path_phantom, blob_phantom, matched };
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

    {
        var pool: vcaligner.Pool = undefined;
        try pool.init(.{ .allocator = gpac.allocator, .n_jobs = runconf.n_jobs - 1 });
        defer pool.deinit();
        var wait_group: std.Thread.WaitGroup = .{};
        // TODO: 将 Git Blob 哈希任务提取到 Strict 与 Topology 共用的模块。
        for (release_files.items) |*file| {
            if (file.repo_path_seq == null) continue;
            pool.spawnWg(&wait_group, collect_artifacts_blob.subTask, .{
                release_dir, file.path, file.kind, &file.blob_hash,
            });
        }
        pool.waitAndWork(&wait_group);
    }

    var evidence_arena_state: vcaligner.ExclusiveRecyclingArena(0).State = .{};
    var evidence_arena_handle = evidence_arena_state.handle(allocator);
    defer evidence_arena_handle.deinit();
    const evidence_allocator = evidence_arena_handle.allocator();
    var evidences: std.ArrayListUnmanaged(Evidence) = .empty;
    defer {
        for (evidences.items) |*evidence| evidence.commit_collection.deinit(evidence_allocator);
        evidences.deinit(evidence_allocator);
    }
    try collectEvidences(storage, release_files.items, &evidences, evidence_allocator, last_diag);

    const SortContext = struct {
        files: []const ReleaseFile,
        fn lessThan(ctx: @This(), a: Evidence, b: Evidence) bool {
            if (a.discriminative != b.discriminative) return a.discriminative;
            if (a.commit_count != b.commit_count) return a.commit_count < b.commit_count;
            return std.mem.order(u8, ctx.files[a.release_file_idx].path, ctx.files[b.release_file_idx].path) == .lt;
        }
    };
    std.sort.pdq(Evidence, evidences.items, SortContext{ .files = release_files.items }, SortContext.lessThan);
    const signature_units = try allocator.alloc(SignatureUnit, evidences.items.len);
    defer allocator.free(signature_units);
    var discriminative_count: u32 = 0;
    for (evidences.items, signature_units, 0..) |*evidence, *unit, i| {
        if (evidence.discriminative) discriminative_count += 1;
        release_files.items[evidence.release_file_idx].evidence_idx = i;
        unit.* = .{ .commit_collection = evidence.commit_collection.view() };
    }
    const candidates = try analyse_candidates.analyseCandidates(signature_units, discriminative_count, gpae, 0);
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
        try files.append(allocator, .{ .path = path, .kind = kind });
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
        files[release_file_idx].repo_path_seq = std.mem.bytesToValue(PathSeq, key_ptr[0..key_len]);
        files[release_file_idx].status = .blob_phantom;
    }
    var err_cstr: ?[*:0]u8 = null;
    c.rocksdb_iter_get_error(iter, @ptrCast(&err_cstr));
    try vcaligner.c_helper.checkRocksdbErr(err_cstr, @src(), last_diag);
}

fn collectEvidences(
    storage: Storage,
    files: []ReleaseFile,
    evidences: *std.ArrayListUnmanaged(Evidence),
    allocator: std.mem.Allocator,
    last_diag: *vcaligner.diag.Diagnostic,
) !void {
    const once_get_roptions = blk: {
        const roptions = c.rocksdb_readoptions_create().?;
        c.rocksdb_readoptions_set_fill_cache(roptions, 0);
        break :blk roptions;
    };
    defer c.rocksdb_readoptions_destroy(once_get_roptions);
    const prefix_scan_roptions = blk: {
        const roptions = c.rocksdb_readoptions_create().?;
        vcaligner.rocksdb_custom.applyPrefixScanToReadOptions(roptions);
        break :blk roptions;
    };
    defer c.rocksdb_readoptions_destroy(prefix_scan_roptions);
    const iter = c.rocksdb_create_iterator_cf(storage.db, prefix_scan_roptions, storage.cfs.get(.bpi_ci)).?;
    defer c.rocksdb_iter_destroy(iter);

    for (files, 0..) |*file, release_file_idx| {
        const path_seq = file.repo_path_seq orelse continue;
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
        if (ptr == null) continue;
        defer c.rocksdb_free(ptr);
        std.debug.assert(blob_path_seq_len == @sizeOf(BlobPathSeq));
        const blob_path_seq = std.mem.bytesToValue(BlobPathSeq, ptr[0..blob_path_seq_len]);

        var builder: CommitCollection.Builder = .init;
        errdefer builder.b.deinit(allocator);
        c.rocksdb_iter_seek(iter, @ptrCast(&blob_path_seq), @sizeOf(BlobPathSeq));
        while (c.rocksdb_iter_valid(iter) != 0) : (c.rocksdb_iter_next(iter)) {
            var key_len: usize = undefined;
            const key_ptr = c.rocksdb_iter_key(iter, &key_len);
            std.debug.assert(key_len == @sizeOf(vcaligner.rocksdb_custom.Key));
            const key = std.mem.bytesToValue(vcaligner.rocksdb_custom.Key, key_ptr[0..key_len]);
            if (key.blob_path_seq != blob_path_seq) break;
            try builder.appendNativeAssumeGreater(allocator, key.commit_seq.toNative());
        }
        const collection = try builder.toOwnedCommitRanges(allocator);
        errdefer collection.deinit(allocator);
        try evidences.append(allocator, .{
            .release_file_idx = release_file_idx,
            .commit_collection = collection,
            .commit_count = collection.view().commitCount(),
            .discriminative = isDiscriminative(file.blob_hash),
        });
        file.status = .matched;
    }
    var err_cstr: ?[*:0]u8 = null;
    c.rocksdb_iter_get_error(iter, @ptrCast(&err_cstr));
    try vcaligner.c_helper.checkRocksdbErr(err_cstr, @src(), last_diag);
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
