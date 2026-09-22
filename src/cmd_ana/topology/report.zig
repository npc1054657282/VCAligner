const std = @import("std");
const AnaRunner = @import("AnaRunner.zig");
const analysis = @import("analysis.zig");
const analyse_blob_topology = @import("analyse_blob_topology.zig");
const analyse_candidates = @import("analyse_candidates.zig");
const vcaligner = @import("vcaligner");
const c_helper = vcaligner.c_helper;
const c = c_helper.c;

pub const Error = error{
    DanglingPathSeq,
    DanglingCommitSeq,
    InvalidCommitHashLength,
};

pub fn report(
    report_output: *const AnaRunner.ReportOutputConf,
    candidates: []const analyse_candidates.Candidate,
    storage: vcaligner.cli.ana_runner.Storage,
    agendas: []const analysis.AgendaUnit,
    release_artifact_blob_manifest: *const analysis.ReleaseArtifactBlobManifest,
    blob_analysis_results: []const analyse_blob_topology.BlobAnalysisResult,
    release_path_depot: *const analysis.release_artifact.PathDepot,
    gpa: analysis.mainWorkerManagedGpa,
    last_diag: *vcaligner.diag.Diagnostic,
) !void {
    var repo_paths_arena: vcaligner.StArena = .init(gpa.allocator());
    defer repo_paths_arena.deinit();
    var repo_paths_map: std.AutoHashMapUnmanaged(
        vcaligner.rocksdb_custom.PathSeq,
        [:0]const u8,
    ) = .empty;
    defer repo_paths_map.deinit(gpa.allocator());
    repo_paths_map_build: {
        const roptions = c.rocksdb_readoptions_create().?;
        defer c.rocksdb_readoptions_destroy(roptions);
        for (blob_analysis_results) |*blob_analysis_result| {
            for (blob_analysis_result.repo_path_seqs) |pi| {
                const gop = try repo_paths_map.getOrPut(gpa.allocator(), pi);
                if (gop.found_existing) continue;
                const repo_path = blk: {
                    var err_cstr: ?[*:0]u8 = null;
                    var vallen: usize = undefined;
                    const repo_path_ptr = c.rocksdb_get_cf(
                        storage.db,
                        roptions,
                        storage.cfs.get(.pi2p),
                        @ptrCast(&pi),
                        @sizeOf(vcaligner.rocksdb_custom.PathSeq),
                        &vallen,
                        @ptrCast(&err_cstr),
                    );
                    try c_helper.checkRocksdbErr(err_cstr, @src(), last_diag);
                    if (repo_path_ptr == null) {
                        std.log.err("rocksdb path seq {d} not found!" ++
                            \\
                            \\This probably means that the rocksdb database the analysis was based on does not conform to expectations. 
                            \\Use the `vcaligner prep` subcommand to regenerate a valid rocksdb database.
                        , .{pi.toNative()});
                        return Error.DanglingPathSeq;
                    }
                    defer c.rocksdb_free(repo_path_ptr);
                    break :blk try repo_paths_arena.allocator().dupeZ(u8, repo_path_ptr[0..vallen]);
                };
                gop.value_ptr.* = repo_path;
            }
        }
        break :repo_paths_map_build;
    }

    const report_file = switch (report_output.*) {
        .manual => |path| try std.fs.cwd().createFileZ(path, .{}),
        .none => std.fs.File.stdout(),
    };
    defer switch (report_output.*) {
        .manual => report_file.close(),
        .none => {},
    };
    var report_writer_buffer: [
        arbitrary_buffer_size: {
            break :arbitrary_buffer_size 1024;
        }
    ]u8 = undefined;
    var report_writer = report_file.writer(&report_writer_buffer);
    var stringifier: std.json.Stringify = .{ .writer = &report_writer.interface, .options = .{ .whitespace = .indent_4 } };
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
                    const once_get_roptions = blk: {
                        const roptions = c.rocksdb_readoptions_create().?;
                        c.rocksdb_readoptions_set_fill_cache(roptions, 0);
                        break :blk roptions;
                    };
                    defer c.rocksdb_readoptions_destroy(once_get_roptions);
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
                            try c_helper.checkRocksdbErr(err_cstr, @src(), last_diag);
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
                try stringifier.objectField("created_by_agenda");
                try stringifier.write(candidate.created_by_agenda);
                try stringifier.objectField("refined_by_agendas");
                refined_by_agendas: {
                    try stringifier.beginArray();
                    const old_ws = stringifier.options.whitespace;
                    stringifier.options.whitespace = .minified;
                    defer stringifier.options.whitespace = old_ws;
                    for (candidate.refined_by_agendas) |refined_by_agenda_idx| {
                        try stringifier.write(refined_by_agenda_idx);
                    }
                    try stringifier.endArray();
                    break :refined_by_agendas;
                }
                try stringifier.objectField("compatible_agendas");
                compatible_agendas: {
                    try stringifier.beginArray();
                    const old_ws = stringifier.options.whitespace;
                    stringifier.options.whitespace = .minified;
                    defer stringifier.options.whitespace = old_ws;
                    for (candidate.compatible_agendas) |compatible_agenda_idx| {
                        try stringifier.write(compatible_agenda_idx);
                    }
                    try stringifier.endArray();
                    break :compatible_agendas;
                }
                try stringifier.endObject();
            }
            try stringifier.endArray();
            break :candidates;
        }
        try stringifier.objectField("agendas");
        agendas: {
            try stringifier.beginArray();
            for (agendas, 0..) |*agenda_unit, agenda_idx| {
                try stringifier.beginObject();
                try stringifier.objectField("idx");
                try stringifier.write(agenda_idx);
                try stringifier.objectField("blob");
                try stringifier.write(std.fmt.bytesToHex(
                    release_artifact_blob_manifest.entries[agenda_unit.artifact_blob_id].blob_hash.id,
                    .lower,
                ));
                try stringifier.objectField("is_topologically_refined");
                try stringifier.write(agenda_unit.maybe_topology_shape != null);
                try stringifier.objectField("repo_paths");
                repo_paths: {
                    try stringifier.beginArray();
                    render_shape: {
                        const repo_path_seqs: []const vcaligner.rocksdb_custom.PathSeq = blob_analysis_results[agenda_unit.artifact_blob_id].repo_path_seqs;
                        if (agenda_unit.maybe_topology_shape) |shape| {
                            switch (shape) {
                                .single => {
                                    std.debug.assert(repo_path_seqs.len == 1);
                                },
                                inline .dynamic_bitset, .integer_bitset => |*bitset_shape| {
                                    var iter = bitset_shape.raw.iterator(.{});
                                    while (iter.next()) |repo_path_seqs_idx| {
                                        if (repo_paths_map.get(repo_path_seqs[repo_path_seqs_idx])) |repo_path| {
                                            try stringifier.write(repo_path);
                                        } else unreachable;
                                    }
                                    break :render_shape;
                                },
                            }
                        }
                        for (repo_path_seqs) |pi| {
                            if (repo_paths_map.get(pi)) |repo_path| {
                                try stringifier.write(repo_path);
                            } else unreachable;
                        }
                        break :render_shape;
                    }
                    try stringifier.endArray();
                    break :repo_paths;
                }
                try stringifier.endObject();
            }
            try stringifier.endArray();
            break :agendas;
        }
        try stringifier.objectField("match_blobs");
        match_blobs: {
            try stringifier.beginArray();
            for (blob_analysis_results, 0..) |*blob_analysis_result, artifact_blob_idx| {
                if (blob_analysis_result.repo_path_seqs.len == 0) continue;
                const entry = &release_artifact_blob_manifest.entries[artifact_blob_idx];
                try stringifier.beginObject();
                try stringifier.objectField("blob");
                try stringifier.write(std.fmt.bytesToHex(
                    entry.blob_hash.id,
                    .lower,
                ));
                try stringifier.objectField("release_artifact_paths");
                release_artifact_paths: {
                    try stringifier.beginArray();
                    var iter = release_artifact_blob_manifest.release_artifact_paths.slicedView(entry.release_artifact_paths_slicer).iter(release_path_depot);
                    while (iter.next()) |release_artifact_path| {
                        try stringifier.write(release_artifact_path);
                    }
                    try stringifier.endArray();
                    break :release_artifact_paths;
                }
                try stringifier.endObject();
            }
            try stringifier.endArray();
            break :match_blobs;
        }
        try stringifier.objectField("phatom_blobs");
        phatom_blobs: {
            try stringifier.beginArray();
            for (blob_analysis_results, 0..) |*blob_analysis_result, artifact_blob_idx| {
                if (blob_analysis_result.repo_path_seqs.len != 0) continue;
                const entry = &release_artifact_blob_manifest.entries[artifact_blob_idx];
                try stringifier.beginObject();
                try stringifier.objectField("blob");
                try stringifier.write(std.fmt.bytesToHex(
                    entry.blob_hash.id,
                    .lower,
                ));
                try stringifier.objectField("release_artifact_paths");
                release_artifact_paths: {
                    try stringifier.beginArray();
                    var iter = release_artifact_blob_manifest.release_artifact_paths.slicedView(entry.release_artifact_paths_slicer).iter(release_path_depot);
                    while (iter.next()) |release_artifact_path| {
                        try stringifier.write(release_artifact_path);
                    }
                    try stringifier.endArray();
                    break :release_artifact_paths;
                }
                try stringifier.endObject();
            }
            try stringifier.endArray();
            break :phatom_blobs;
        }
        try stringifier.endObject();
        break :output;
    }
    try report_writer.interface.flush();
}
