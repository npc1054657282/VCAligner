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
    var stringifier: std.json.Stringify = .{ .writer = &writer.interface, .options = .{ .whitespace = .indent_4 } };
    const once_get_roptions = blk: {
        const roptions = c.rocksdb_readoptions_create().?;
        c.rocksdb_readoptions_set_fill_cache(roptions, 0);
        break :blk roptions;
    };
    defer c.rocksdb_readoptions_destroy(once_get_roptions);

    output: {
        try stringifier.beginObject();
        try stringifier.objectField("candidates");
        candidates: {
            try stringifier.beginArray();
            for (candidates, 0..) |*candidate, candidate_idx| {
                try stringifier.beginObject();
                try stringifier.objectField("idx");
                try stringifier.write(candidate_idx);
                try stringifier.objectField("commits");
                commits: {
                    try stringifier.beginArray();
                    var iter = candidate.commits.view().iter();
                    while (iter.next()) |ci| {
                        const commit: c.git_oid = commit: {
                            var err_cstr: ?[*:0]u8 = null;
                            var vallen: usize = undefined;
                            const commit_ptr = c.rocksdb_get_cf(
                                storage.db,
                                once_get_roptions,
                                storage.cfs.get(.ci2c),
                                @ptrCast(&ci),
                                @sizeOf(vcaligner.rocksdb_custom.CommitSeq),
                                &vallen,
                                @ptrCast(&err_cstr),
                            );
                            try vcaligner.c_helper.checkRocksdbErr(err_cstr, @src(), last_diag);
                            if (commit_ptr == null) {
                                // 对应的commit不存在
                                std.log.err("rocksdb commit seq {d} not found!" ++
                                    \\
                                    \\This probably means that the rocksdb database the analysis was based on does not conform to expectations. 
                                    \\Use the `vcaligner prep` subcommand to regenerate a valid rocksdb database.
                                , .{ci.toNative()});
                                return Error.DanglingCommitSeq;
                            }
                            defer c.rocksdb_free(commit_ptr);
                            if (vallen != @sizeOf(@FieldType(c.git_oid, "id"))) {
                                std.log.err("Corrupted or incompatible database entry at commit sequence {d}.\n" ++
                                    "Expected a commit hash of length {d} bytes, but retrieved {d} bytes." ++
                                    \\
                                    \\This probably means that the rocksdb database the analysis was based on does not conform to expectations. 
                                    \\Use the `vcaligner prep` subcommand to regenerate a valid rocksdb database.
                                , .{ ci.toNative(), @sizeOf(@FieldType(c.git_oid, "id")), vallen });
                                return Error.InvalidCommitHashLength;
                            }
                            break :commit .{
                                .id = std.mem.bytesToValue(@FieldType(c.git_oid, "id"), commit_ptr),
                            };
                        };
                        try stringifier.write(std.fmt.bytesToHex(commit.id, .lower));
                    }
                    try stringifier.endArray();
                    break :commits;
                }
                try stringifier.objectField("compatible_evidences");
                compatible_evidences: {
                    try stringifier.beginArray();
                    const old_ws = stringifier.options.whitespace;
                    stringifier.options.whitespace = .minified;
                    defer stringifier.options.whitespace = old_ws;
                    const signature = candidate.signature.promote(evidences.len);
                    var matches = signature.iterator(.{});
                    while (matches.next()) |evidence_idx| try stringifier.write(evidence_idx);
                    try stringifier.endArray();
                    break :compatible_evidences;
                }
                try stringifier.endObject();
            }
            try stringifier.endArray();
            break :candidates;
        }

        try stringifier.objectField("evidences");
        evidences: {
            try stringifier.beginArray();
            for (evidences, 0..) |*evidence, idx| {
                const release_file = release_files[evidence.release_file_idx];
                try stringifier.beginObject();
                try stringifier.objectField("idx");
                try stringifier.write(idx);
                try stringifier.objectField("path");
                try stringifier.write(release_file.path);
                try stringifier.objectField("blob");
                try stringifier.write(std.fmt.bytesToHex(release_file.blob_hash.id, .lower));
                try stringifier.objectField("discriminative");
                try stringifier.write(evidence.discriminative);
                try stringifier.objectField("commit_count");
                try stringifier.write(evidence.commit_count);
                try stringifier.endObject();
            }
            try stringifier.endArray();
            break :evidences;
        }

        try stringifier.objectField("match_files");
        match_files: {
            try stringifier.beginArray();
            for (release_files) |release_file| {
                if (release_file.status != .matched) continue;
                try stringifier.beginObject();
                try stringifier.objectField("path");
                try stringifier.write(release_file.path);
                try stringifier.objectField("evidence_idx");
                try stringifier.write(release_file.evidence_idx.?);
                try stringifier.endObject();
            }
            try stringifier.endArray();
            break :match_files;
        }

        try stringifier.objectField("release_phantom_files");
        release_phantom_files: {
            try stringifier.beginArray();
            for (release_files) |release_file| {
                if (release_file.status == .path_phantom) try stringifier.write(release_file.path);
            }
            try stringifier.endArray();
            break :release_phantom_files;
        }

        try stringifier.objectField("dismatch_phantom_files");
        dismatch_phantom_files: {
            try stringifier.beginArray();
            for (release_files) |release_file| {
                if (release_file.status == .blob_phantom) try stringifier.write(release_file.path);
            }
            try stringifier.endArray();
            break :dismatch_phantom_files;
        }

        try stringifier.objectField("repo_only_files");
        repo_only_files: {
            try stringifier.beginArray();
            try writeRepoOnlyFiles(&stringifier, storage, once_get_roptions, release_by_path, package_directory, last_diag);
            try stringifier.endArray();
            break :repo_only_files;
        }
        try stringifier.endObject();
        break :output;
    }
    try writer.interface.flush();
}

fn writeRepoOnlyFiles(
    stringifier: *std.json.Stringify,
    storage: Storage,
    once_get_roptions: *c.rocksdb_readoptions_t,
    release_by_path: *const std.StringHashMapUnmanaged(usize),
    package_directory: ?[:0]const u8,
    last_diag: *vcaligner.diag.Diagnostic,
) !void {
    const full_scan_roptions = blk: {
        const roptions = c.rocksdb_readoptions_create().?;
        vcaligner.rocksdb_custom.applyFullScanOfOrderPreservingTypedKeyToReadOptions(roptions, PathRankBlobCountKey);
        break :blk roptions;
    };
    defer c.rocksdb_readoptions_destroy(full_scan_roptions);
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
        if (!release_by_path.contains(path)) try stringifier.write(path);
    }
    var err_cstr: ?[*:0]u8 = null;
    c.rocksdb_iter_get_error(iter, @ptrCast(&err_cstr));
    try vcaligner.c_helper.checkRocksdbErr(err_cstr, @src(), last_diag);
}
