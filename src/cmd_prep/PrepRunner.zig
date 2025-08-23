const std = @import("std");
const zargs = @import("zargs");
const CliRunner = @import("gvca").cli.Runner;
const c = @import("gvca").c_helper.c;
const diag = @import("gvca").diag;
const PrepRunner = @This();
const mpsc_queue = @import("mpsc_queue");
const MpscChannel = @import("gvca").MpscChannel;
pub const Parsed = struct {
    pad: [72]u8,
};
pub const Queue = mpsc_queue.AnyMpscQueue(Parsed, null);
pub const Channel = MpscChannel(Queue);

global: CliRunner.Global,
bare_repo_path: [:0]u8,
n_jobs: usize,
task_queue_capacity_log2: u8,
repo: *c.git_repository = undefined,
odb: *c.git_odb = undefined,
repo_id: [:0]u8 = undefined,
commit_registry: struct {
    // XXX: HashMap不记录插入顺序，而ArrayHashMap只要不删除内部元素就能确保记录插入顺序。ArrayHashMap有高得多的迭代效率。
    // 目前还不知道有什么需要回溯插入顺序的地方，也暂时没想到迭代需求。如果未来有迭代需求，会考虑改用ArrayHashMap。
    // 目前基于最高查询效率的目的采用HashMap
    table: std.AutoHashMapUnmanaged(c.git_oid, void) = .empty,
    arena: std.heap.ArenaAllocator,
    next_commit_seq: usize = 0, // 每个commit分配一个序列号，因为commit太长了，写入时使用序列号可以提升存储效率。
} = undefined,
parsers: struct {
    pool: std.Thread.Pool,
    wait_group: std.Thread.WaitGroup = .{},
} = undefined,
channel: Channel = undefined,

pub const cmd = CliRunner.Global.sharedArgs(zargs.Command.new("prep"))
    .arg(zargs.Arg.optArg("repo_path", ?[]const u8).long("repo-path"))
    .arg(zargs.Arg.optArg("bare_repo_path", ?[]const u8).long("bare-repo-path"))
    .arg(zargs.Arg.optArg("jobs", ?usize).short('j').long("jobs"))
    .arg(zargs.Arg.optArg("task_queue_capacity_log2", u8).long("task-queue-capacity-log2").default(10));
pub fn run(self: *PrepRunner, allocator: std.mem.Allocator, last_diag: *diag.Diagnostic) !void {
    try @import("preprocess.zig").preprocess(self, allocator, last_diag);
    return;
}
pub fn initFromArgs(args: PrepRunner.cmd.Result(), allocator: std.mem.Allocator) !CliRunner {
    var building_bare_repo_path: std.ArrayListUnmanaged(u8) = .empty;
    errdefer building_bare_repo_path.deinit(allocator);
    if (args.bare_repo_path) |bare_repo_path| {
        try building_bare_repo_path.appendSlice(allocator, bare_repo_path);
    } else if (args.repo_path) |repo_path| {
        try building_bare_repo_path.appendSlice(allocator, repo_path);
        try building_bare_repo_path.appendSlice(allocator, "/.git");
    } else {
        std.log.err("Option `bare-repo-path` or `repo-path` is necessary.", .{});
        return CliRunner.Error.CliArgInvalidInput;
    }
    return .{ .prep = .{
        .global = CliRunner.Global.initGlobal(args),
        .bare_repo_path = try building_bare_repo_path.toOwnedSliceSentinel(allocator, 0),
        .n_jobs = if (args.jobs) |jobs| jobs else try std.Thread.getCpuCount(),
        .task_queue_capacity_log2 = args.task_queue_capacity_log2,
    } };
}
pub fn deinit(self: *PrepRunner, allocator: std.mem.Allocator) void {
    allocator.free(self.bare_repo_path);
    self.bare_repo_path = undefined;
}
