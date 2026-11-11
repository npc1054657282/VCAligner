const std = @import("std");
const vcaligner = @import("vcaligner");
const cli = vcaligner.cli;
const diag = vcaligner.diag;
const AnaRunner = @This();

pub const ReportOutputConf = cli.ana_runner.Topology.ReportOutputConf;
const cmd = cli.ana_runner.cmd;

global: cli.Runner.Global,
rocksdb_path: [:0]u8,
release_path: [:0]u8,
report_output: ReportOutputConf,
package_directory: ?[:0]u8,
point_lookup_cache_mb: u64,
n_jobs: usize,

pub fn initFromArgs(args: cmd.Result(), allocator: std.mem.Allocator) !cli.Runner {
    const n_jobs = if (args.jobs) |jobs| jobs else try std.Thread.getCpuCount();
    if (n_jobs == 0) return error.CliArgInvalidInput;
    return .{
        .ana_strict_no_greedy = .{
            .global = .init(args),
            .rocksdb_path = try allocator.dupeZ(u8, args.rocksdb_path),
            .release_path = try allocator.dupeZ(u8, args.release_path),
            .report_output = if (args.report_output) |path|
                .{ .manual = try allocator.dupeZ(u8, path) }
            else
                .none,
            .package_directory = if (args.package_directory) |directory|
                try cli.ana_runner.Strict.normalizePackageDirectory(allocator, directory)
            else
                null,
            .point_lookup_cache_mb = args.point_lookup_cache_mb,
            .n_jobs = n_jobs,
        },
    };
}

pub fn run(noalias self: *const AnaRunner, gpa: vcaligner.gpa.Concurrent, last_diag: *diag.Diagnostic) !void {
    try @import("analysis.zig").analysis(self, gpa, last_diag);
}

pub fn deinit(noalias self: *const AnaRunner, allocator: std.mem.Allocator) void {
    allocator.free(self.rocksdb_path);
    allocator.free(self.release_path);
    switch (self.report_output) {
        .manual => |path| allocator.free(path),
        .none => {},
    }
    if (self.package_directory) |directory| allocator.free(directory);
}
