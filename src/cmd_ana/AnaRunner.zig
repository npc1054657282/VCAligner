const std = @import("std");
const zargs = @import("zargs");
const gvca = @import("gvca");
const c = gvca.c_helper.c;
const diag = gvca.diag;
const PathSeq = gvca.rocksdb_custom.PathSeq;
const CliRunner = gvca.cli.Runner;
const AnaRunner = @This();

global: CliRunner.Global,
rocksdb_path: [:0]u8,
release_path: [:0]u8,
point_lookup_cache_mb: u64,
n_jobs: usize,
db: *c.struct_rocksdb_t = undefined,
cf_pbi_ci: *c.rocksdb_column_family_handle_t = undefined,
cf_pi_p: *c.rocksdb_column_family_handle_t = undefined,
cf_pi_b_pbi: *c.rocksdb_column_family_handle_t = undefined,
candidate_parser: struct {
    agenda_parsers: std.ArrayListAligned(struct {
        pi: PathSeq, // 输入。
        maybe_path: ?[:0]u8 = null,
        maybe_commit_ranges: ?[]gvca.commit_range.CommitRange = null, // 输出，需要注意管理内存
    }, std.mem.Alignment.fromByteUnits(std.atomic.cache_line)),
    candidates: std.ArrayList(struct {
        commit_ranges: []gvca.commit_range.CommitRange,
    }),
    once_get_roptions: *c.struct_rocksdb_readoptions_t, // 用于pi2p、pib2pbi的读取
    prefix_scan_roptions: *c.struct_rocksdb_readoptions_t, // 用于default的读取
    pub fn init() @This() {
        return .{
            .agenda_parsers = .empty,
            .candidates = .empty,
            .once_get_roptions = blk: {
                const roptions = c.rocksdb_readoptions_create();
                // 每个键只会被`get`一次，不用缓存避免污染。
                c.rocksdb_readoptions_set_fill_cache(roptions, 0);
                break :blk roptions.?;
            },
            .prefix_scan_roptions = blk: {
                const roptions = c.rocksdb_readoptions_create();
                c.rocksdb_readoptions_set_fill_cache(roptions, 1);
                c.rocksdb_readoptions_set_prefix_same_as_start(roptions, 1);
                c.rocksdb_readoptions_set_auto_readahead_size(roptions, 1);
                break :blk roptions.?;
            },
        };
    }
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        for (self.agenda_parsers.items) |*item| {
            if (item.maybe_commit_ranges) |commit_ranges| allocator.free(commit_ranges);
            if (item.maybe_path) |path| allocator.free(path);
        }
        self.agenda_parsers.deinit(allocator);
        for (self.candidates.items) |*item| {
            allocator.free(item.commit_ranges);
        }
        self.candidates.deinit(allocator);
        c.rocksdb_readoptions_destroy(self.once_get_roptions);
        c.rocksdb_readoptions_destroy(self.prefix_scan_roptions);
        self.* = undefined;
    }
} = undefined,

pub const cmd = CliRunner.Global.sharedArgs(zargs.Command.new("ana"))
    .arg(zargs.Arg.optArg("rocksdb_path", []const u8).long("rocksdb-path"))
    .arg(zargs.Arg.optArg("release_path", []const u8).long("release-path"))
    .arg(zargs.Arg.optArg("point_lookup_cache_mb", u64).long("point-lookup-cache-mb").default(512))
    .arg(zargs.Arg.optArg("jobs", ?usize).short('j').long("jobs"));

pub fn run(self: *AnaRunner, allocator: std.mem.Allocator, last_diag: *diag.Diagnostic) !void {
    try @import("analysis.zig").analysis(self, allocator, last_diag);
    return;
}
pub fn initFromArgs(args: AnaRunner.cmd.Result(), allocator: std.mem.Allocator) !CliRunner {
    const n_jobs = if (args.jobs) |jobs| jobs else try std.Thread.getCpuCount();
    return .{
        .ana = .{
            .global = CliRunner.Global.initGlobal(args),
            .rocksdb_path = try allocator.dupeZ(u8, args.rocksdb_path),
            .release_path = try allocator.dupeZ(u8, args.release_path),
            .point_lookup_cache_mb = args.point_lookup_cache_mb,
            .n_jobs = n_jobs,
        },
    };
}
pub fn deinit(self: *AnaRunner, allocator: std.mem.Allocator) void {
    allocator.free(self.rocksdb_path);
    self.rocksdb_path = undefined;
    allocator.free(self.release_path);
    self.release_path = undefined;
}
