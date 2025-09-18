const std = @import("std");
const zargs = @import("zargs");
const gvca = @import("gvca");
const diag = gvca.diag;
const CliRunner = gvca.cli.Runner;
const AnaRunner = @This();

global: CliRunner.Global,
rocksdb_path: [:0]u8,
release_path: [:0]u8,
point_lookup_cache_mb: u64,

pub const cmd = CliRunner.Global.sharedArgs(zargs.Command.new("ana"))
    .arg(zargs.Arg.optArg("rocksdb_path", []const u8).long("rocksdb-path"))
    .arg(zargs.Arg.optArg("release_path", []const u8).long("release-path"))
    .arg(zargs.Arg.optArg("point_lookup_cache_mb", u64).long("point-lookup-cache-mb").default(512));

pub fn run(self: *AnaRunner, allocator: std.mem.Allocator, last_diag: *diag.Diagnostic) !void {
    try @import("analysis.zig").analysis(self, allocator, last_diag);
    return;
}
pub fn initFromArgs(args: AnaRunner.cmd.Result(), allocator: std.mem.Allocator) !CliRunner {
    return .{
        .ana = .{
            .global = CliRunner.Global.initGlobal(args),
            .rocksdb_path = try allocator.dupeZ(u8, args.rocksdb_path),
            .release_path = try allocator.dupeZ(u8, args.release_path),
            .point_lookup_cache_mb = args.point_lookup_cache_mb,
        },
    };
}
pub fn deinit(self: *AnaRunner, allocator: std.mem.Allocator) void {
    allocator.free(self.rocksdb_path);
    self.rocksdb_path = undefined;
    allocator.free(self.release_path);
    self.release_path = undefined;
}
