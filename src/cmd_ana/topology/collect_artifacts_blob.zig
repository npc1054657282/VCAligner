//! 此阶段将分发包的各个文件转换为git hash blob，此外，最终将相同blob归并在一起。
const std = @import("std");
const vcaligner = @import("vcaligner");
const c = vcaligner.c_helper.c;
const analysis = @import("analysis.zig");

pub fn collectArtifactsBlob(
    pool: *vcaligner.Pool,
    release_path: [:0]const u8,
    gpa: analysis.mainWorkerManagedGpa,
) !struct {
    analysis.release_artifact.Paths,
    analysis.release_artifact.Node.Depot,
    analysis.BlobAgendas.Building,
} {
    var release_artifact_paths_appending: analysis.release_artifact.Paths.PinnedAppending = .init(gpa);
    errdefer release_artifact_paths_appending.deinit();
    var node_depot_appending: analysis.release_artifact.Node.Depot.PinnedAppending = .init(gpa);
    errdefer node_depot_appending.deinit();
    var blob_agendas_building: analysis.BlobAgendas.Building = .{ .list = .empty };
    errdefer blob_agendas_building.deinit(gpa);
    var release_dir = try std.fs.cwd().openDirZ(release_path, .{ .iterate = true });
    defer release_dir.close();
    var wait_group: std.Thread.WaitGroup = .{};
    defer pool.waitAndWork(&wait_group);
    var walker = try release_dir.walk(gpa.allocator());
    while (try walker.next()) |entry| {
        if (entry.kind == .directory) continue;
        const pi = try release_artifact_paths_appending.appendDupeZ(entry.path);
        const ni = try node_depot_appending.create();
        try blob_agendas_building.append(gpa, ni);
        const node = node_depot_appending.get(ni);
        node.* = .{ .path_i = pi, .blob_hash = undefined };
        pool.spawnWg(&wait_group, subTask, .{
            release_artifact_paths_appending.get(pi),
            &node.blob_hash,
        });
    }
    return .{
        release_artifact_paths_appending.toUnpinned(),
        node_depot_appending.toUnpinned(),
        blob_agendas_building,
    };
}

pub fn subTask(
    release_artifact_path: [:0]const u8,
    blob_hash_out: *c.git_oid,
) void {
    _ = release_artifact_path;
    _ = blob_hash_out;
    // TODO
}
