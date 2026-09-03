const std = @import("std");
const zargs = @import("zargs");
const vcaligner = @import("vcaligner");
const diag = vcaligner.diag;
const cli = vcaligner.cli;
const AnaRunner = @This();

global: cli.Runner.Global,
rocksdb_path: [:0]u8,
release_path: [:0]u8,
report_output: union(enum) {
    manual: [:0]u8,
    none: void,
},
point_lookup_cache_mb: u64,
n_jobs: usize,

const cmd = cli.ana_runner.cmd;

pub fn run(noalias self: *const AnaRunner, gpa: vcaligner.gpa.Concurrent, last_diag: *diag.Diagnostic) !void {
    try @import("analysis.zig").analysis(self, gpa, last_diag);
    return;
}

pub fn initFromArgs(args: cmd.Result(), allocator: std.mem.Allocator) !cli.Runner {
    const n_jobs = if (args.jobs) |jobs| jobs else try std.Thread.getCpuCount();
    return .{
        .ana_topology = .{
            .global = .init(args),
            .rocksdb_path = try allocator.dupeZ(u8, args.rocksdb_path),
            .release_path = try allocator.dupeZ(u8, args.release_path),
            .report_output = if (args.report_output) |report_output| .{
                .manual = try allocator.dupeZ(u8, report_output),
            } else .none,
            .point_lookup_cache_mb = args.point_lookup_cache_mb,
            .n_jobs = n_jobs,
        },
    };
}
pub fn deinit(noalias self: *const AnaRunner, allocator: std.mem.Allocator) void {
    allocator.free(self.rocksdb_path);
    allocator.free(self.release_path);
    switch (self.report_output) {
        .manual => |manual| allocator.free(manual),
        .none => {},
    }
}
