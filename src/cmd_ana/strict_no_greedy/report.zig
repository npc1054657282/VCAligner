const std = @import("std");
const vcaligner = @import("vcaligner");
const c = vcaligner.c_helper.c;
const AnaRunner = @import("AnaRunner.zig");
const analysis = @import("analysis.zig");
const Candidate = @import("analyse_candidates.zig").Candidate;
const Storage = vcaligner.cli.ana_runner.Storage;
const PathSeq = vcaligner.rocksdb_custom.PathSeq;
const PathRankBlobCountKey = vcaligner.rocksdb_custom.PathRankBlobCountKey;

pub const Error = error{ DanglingCommitSeq, DanglingPathSeq, InvalidCommitHashLength };

pub fn report(
    output: *const AnaRunner.ReportOutputConf,
    candidates: []const Candidate,
    evidences: []const analysis.Evidence,
    release_files: []const analysis.ReleaseFile,
    release_by_path: *const std.StringHashMapUnmanaged(usize),
    package_directory: ?[:0]const u8,
    storage: Storage,
    last_diag: *vcaligner.diag.Diagnostic,
) !void {
    const file = switch (output.*) {
        .manual => |path| try std.fs.cwd().createFileZ(path, .{}),
        .none => std.fs.File.stdout(),
    };
    defer switch (output.*) {
        .manual => file.close(),
        .none => {},
    };
    var buffer: [1024]u8 = undefined;
    var writer = file.writer(&buffer);
    var json: std.json.Stringify = .{ .writer = &writer.interface, .options = .{ .whitespace = .indent_4 } };
    const once_get_roptions = c.rocksdb_readoptions_create().?;
    defer c.rocksdb_readoptions_destroy(once_get_roptions);
    c.rocksdb_readoptions_set_fill_cache(once_get_roptions, 0);

    try json.beginObject();
    try json.objectField("candidates");
    try json.beginArray();
    for (candidates, 0..) |*candidate, candidate_idx| {
        try json.beginObject();
        try json.objectField("idx");
        try json.write(candidate_idx);
        try json.objectField("commits");
        try json.beginArray();
        var iter = candidate.commits.view().iter();
        while (iter.next()) |ci| {
            var err_cstr: ?[*:0]u8 = null;
            var len: usize = undefined;
            const ptr = c.rocksdb_get_cf(
                storage.db,
                once_get_roptions,
                storage.cfs.get(.ci2c),
                @ptrCast(&ci),
                @sizeOf(vcaligner.rocksdb_custom.CommitSeq),
                &len,
                @ptrCast(&err_cstr),
            );
            try vcaligner.c_helper.checkRocksdbErr(err_cstr, @src(), last_diag);
            if (ptr == null) return Error.DanglingCommitSeq;
            defer c.rocksdb_free(ptr);
            if (len != @sizeOf(@FieldType(c.git_oid, "id"))) return Error.InvalidCommitHashLength;
            const hash = std.mem.bytesToValue(@FieldType(c.git_oid, "id"), ptr[0..len]);
            try json.write(std.fmt.bytesToHex(hash, .lower));
        }
        try json.endArray();
        try json.objectField("compatible_evidences");
        try json.beginArray();
        const signature = candidate.signature.promote(evidences.len);
        var matches = signature.iterator(.{});
        while (matches.next()) |evidence_idx| try json.write(evidence_idx);
        try json.endArray();
        try json.endObject();
    }
    try json.endArray();

    try json.objectField("evidences");
    try json.beginArray();
    for (evidences, 0..) |*evidence, idx| {
        const release_file = release_files[evidence.release_file_idx];
        try json.beginObject();
        try json.objectField("idx");
        try json.write(idx);
        try json.objectField("path");
        try json.write(release_file.path);
        try json.objectField("blob");
        try json.write(std.fmt.bytesToHex(release_file.blob_hash.id, .lower));
        try json.objectField("discriminative");
        try json.write(evidence.discriminative);
        try json.objectField("commit_count");
        try json.write(evidence.commit_count);
        try json.endObject();
    }
    try json.endArray();

    try json.objectField("match_files");
    try json.beginArray();
    for (release_files) |release_file| {
        if (release_file.status != .matched) continue;
        try json.beginObject();
        try json.objectField("path");
        try json.write(release_file.path);
        try json.objectField("evidence_idx");
        try json.write(release_file.evidence_idx.?);
        try json.endObject();
    }
    try json.endArray();

    try json.objectField("release_phatom_files");
    try json.beginArray();
    for (release_files) |release_file| {
        if (release_file.status == .path_phantom) try json.write(release_file.path);
    }
    try json.endArray();

    try json.objectField("dismatch_phatom_files");
    try json.beginArray();
    for (release_files) |release_file| {
        if (release_file.status == .blob_phantom) try json.write(release_file.path);
    }
    try json.endArray();

    try json.objectField("repo_only_files");
    try json.beginArray();
    try writeRepoOnlyFiles(&json, storage, once_get_roptions, release_by_path, package_directory, last_diag);
    try json.endArray();
    try json.endObject();
    try writer.interface.flush();
}

fn writeRepoOnlyFiles(
    json: *std.json.Stringify,
    storage: Storage,
    once_get_roptions: *c.rocksdb_readoptions_t,
    release_by_path: *const std.StringHashMapUnmanaged(usize),
    package_directory: ?[:0]const u8,
    last_diag: *vcaligner.diag.Diagnostic,
) !void {
    const full_scan_roptions = c.rocksdb_readoptions_create().?;
    defer c.rocksdb_readoptions_destroy(full_scan_roptions);
    vcaligner.rocksdb_custom.applyFullScanOfOrderPreservingTypedKeyToReadOptions(full_scan_roptions, PathRankBlobCountKey);
    const iter = c.rocksdb_create_iterator_cf(storage.db, full_scan_roptions, storage.cfs.get(.pr_bc2pi)).?;
    defer c.rocksdb_iter_destroy(iter);
    c.rocksdb_iter_seek_to_first(iter);
    while (c.rocksdb_iter_valid(iter) != 0) : (c.rocksdb_iter_next(iter)) {
        var pi_len: usize = undefined;
        const pi_ptr = c.rocksdb_iter_value(iter, &pi_len);
        std.debug.assert(pi_len == @sizeOf(PathSeq));
        const pi = std.mem.bytesToValue(PathSeq, pi_ptr[0..pi_len]);
        var err_cstr: ?[*:0]u8 = null;
        var path_len: usize = undefined;
        const path_ptr = c.rocksdb_get_cf(
            storage.db,
            once_get_roptions,
            storage.cfs.get(.pi2p),
            @ptrCast(&pi),
            @sizeOf(PathSeq),
            &path_len,
            @ptrCast(&err_cstr),
        );
        try vcaligner.c_helper.checkRocksdbErr(err_cstr, @src(), last_diag);
        if (path_ptr == null) return Error.DanglingPathSeq;
        defer c.rocksdb_free(path_ptr);
        const path = analysis.relativeRepoPath(path_ptr[0..path_len], package_directory) orelse continue;
        if (!release_by_path.contains(path)) try json.write(path);
    }
    var err_cstr: ?[*:0]u8 = null;
    c.rocksdb_iter_get_error(iter, @ptrCast(&err_cstr));
    try vcaligner.c_helper.checkRocksdbErr(err_cstr, @src(), last_diag);
}
