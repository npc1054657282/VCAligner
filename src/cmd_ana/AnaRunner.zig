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
report_output: union(enum) {
    manual: [:0]u8,
    none: void,
},
package_directory: ?[:0]u8, // 一些场景下，包对应的是repo的一个子目录而非整个仓库。
point_lookup_cache_mb: u64,
n_jobs: usize,
db: *c.struct_rocksdb_t = undefined,
cf_pbi_ci: *c.rocksdb_column_family_handle_t = undefined,
cf_pi_p: *c.rocksdb_column_family_handle_t = undefined,
cf_pi_b_pbi: *c.rocksdb_column_family_handle_t = undefined,
candidate_parser: struct {
    agenda_parsers: std.ArrayListAligned(struct {
        pi: PathSeq, // 输入。
        // XXX: 一个设计思路是，将`path`和`commit_collection`一起放到一个`union(enum)`里判断是否`unparsed`，然后再对`commit_collection`分三种解析结果讨论。
        // 虽然这个思路看起来很健全，但其实有隐患：path和commit_collection其实是分步骤解析的，而`unparsed`是`undefined`的安全版，以防止错误退出时没能正确析构。
        // 因此，各自保存各自的`unparsed`才是真实合理的方案。
        // 在当前实现中，如果`commit_collection`为`unparsed`和`path_not_in_package_directory`，`path`保留为`unparsed`。
        // 如果`commit_collection`为`path_not_find_in_release`、`path_blob_not_match`和`parsed`，`path`将被解析为package_directory下的相对路径。
        path: union(enum) {
            unparsed: void,
            parsed: [:0]u8,
        } = .unparsed,
        commit_collection: union(enum) {
            unparsed: void,
            path_not_in_package_directory: void,
            path_not_find_in_release: void,
            path_blob_not_match: void,
            parsed: gvca.commit_range.CommitCollection,
        } = .unparsed,
        affect_candidates_idx: std.ArrayList(usize) = .empty, // 如果这个agenda让一个candidate在取交集时缩小了，就说这个agenda影响了这个candidate。此处的usize指candidates中的index
        included_in_candidates_idx: std.ArrayList(usize) = .empty, // 一个agenda只要和candidate取交集不为空，就说这个agenda被这个cadidate包含。此处的usize指candidates中的index
    }, std.mem.Alignment.fromByteUnits(std.atomic.cache_line)),
    candidates: std.ArrayList(struct {
        commit_collection: gvca.commit_range.CommitCollection,
        parsed: std.ArrayList(c.git_oid) = .empty,
        created_by_agenda_idx: usize, // 记录创建这个候选者的agenda，usize是agenda_parsers中的index
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
            switch (item.path) {
                .parsed => |parsed| allocator.free(parsed),
                .unparsed => {},
            }
            switch (item.commit_collection) {
                .parsed => |parsed| parsed.deinit(allocator),
                .unparsed, .path_not_find_in_release, .path_blob_not_match, .path_not_in_package_directory => {},
            }
            item.affect_candidates_idx.deinit(allocator);
            item.included_in_candidates_idx.deinit(allocator);
        }
        self.agenda_parsers.deinit(allocator);
        for (self.candidates.items) |*item| {
            item.commit_collection.deinit(allocator);
            item.parsed.deinit(allocator);
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
    .arg(zargs.Arg.optArg("report_output", ?[]const u8).long("report-output").short('o'))
    .arg(zargs.Arg.optArg("package_directory", ?[]const u8).long("package-directory"))
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
            .report_output = if (args.report_output) |report_output| .{
                .manual = try allocator.dupeZ(u8, report_output),
            } else .none,
            .package_directory = if (args.package_directory) |package_directory| try allocator.dupeZ(u8, package_directory) else null,
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
    switch (self.report_output) {
        .manual => |manual| allocator.free(manual),
        .none => {},
    }
    if (self.package_directory) |package_directory| allocator.free(package_directory);
    self.* = undefined;
}
