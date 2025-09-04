const std = @import("std");
const zargs = @import("zargs");
const CliRunner = @import("gvca").cli.Runner;
const c = @import("gvca").c_helper.c;
const diag = @import("gvca").diag;
const PrepRunner = @This();
const mpsc_queue = @import("mpsc_queue");
const MpscChannel = @import("gvca").MpscChannel;

pub const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    commit_hash: ?c.git_oid,
    commit_seq: usize,
    // 可能并非必要，因为已经在arena中分配？
    // path_strings: std.ArrayList(u8),
    parsed_units: std.ArrayList(ParsedUnit),

    pub const ParsedUnit = struct {
        path: []u8,
        blob: c.git_oid,
    };
};
pub const Queue = mpsc_queue.AnyMpscQueue(Parsed, null);
pub const Channel = MpscChannel(Queue);

global: CliRunner.Global,
bare_repo_path: [:0]u8,
rocksdb_output: [:0]u8,
// 指代计算密集型任务。rocksdb的flush多为I/O密集型任务，不在`n_jobs`考虑范围内
n_jobs: usize,
task_queue_capacity_log2: u5,
repo: *c.git_repository = undefined,
odb: *c.git_odb = undefined,
repo_id: [:0]u8 = undefined,
parsers: struct {
    pool: std.Thread.Pool,
    wait_group: std.Thread.WaitGroup,
    lctxs: std.ArrayListAlignedUnmanaged(@import("parse.zig").Parsing, std.mem.Alignment.fromByteUnits(std.atomic.cache_line)),
    // 记录队列中的任务数量。
    task_in_queue_count: std.atomic.Value(usize) align(std.atomic.cache_line),
    const Parsers = @This();
    pub fn init(self: *Parsers, allocator: std.mem.Allocator, n_parserjobs: usize, channel: *Channel) !void {
        try self.pool.init(.{ .allocator = allocator, .n_jobs = n_parserjobs, .track_ids = true });
        self.wait_group = .{};
        self.lctxs = .empty;
        // 注：实际上的id数量为线程池数量加1，这一点从`pool.init`的实现里就能看出。这是因为创建线程池的线程自己是id 0。
        for (try self.lctxs.addManyAsSlice(allocator, 1 + n_parserjobs)) |*lctx| {
            lctx.init(channel);
        }
    }
    pub fn deinit(self: *Parsers, allocator: std.mem.Allocator) void {
        for (self.lctxs.items) |*lctx| {
            lctx.deinit();
        }
        self.lctxs.deinit(allocator);
        self.pool.deinit();
        self.* = undefined;
    }
} = undefined,
channel: Channel = undefined,
// 下列内容是在各线程已经被创建后，主线程依旧会修改的可变内容，应缓存行对齐，以避免各线程读取上列对各线程而言的只读内容时遭遇伪共享。
commit_registry: struct {
    // XXX: HashMap不记录插入顺序，而ArrayHashMap只要不删除内部元素就能确保记录插入顺序。ArrayHashMap有高得多的迭代效率。
    // 目前还不知道有什么需要回溯插入顺序的地方，也暂时没想到迭代需求。如果未来有迭代需求，会考虑改用ArrayHashMap。
    // 目前基于最高查询效率的目的采用HashMap
    table: std.AutoHashMapUnmanaged(c.git_oid, void) = .empty,
    arena: std.heap.ArenaAllocator,
    next_commit_seq: usize = 0, // 每个commit分配一个序列号，因为commit太长了，写入时使用序列号可以提升存储效率。
} align(std.atomic.cache_line) = undefined,

pub const cmd = CliRunner.Global.sharedArgs(zargs.Command.new("prep"))
    .arg(zargs.Arg.optArg("repo_path", ?[]const u8).long("repo-path"))
    .arg(zargs.Arg.optArg("bare_repo_path", ?[]const u8).long("bare-repo-path"))
    .arg(zargs.Arg.optArg("rocksdb_output", []const u8).long("rocksdb-output").short('o').default("./tmp/rocksdb-output"))
    .arg(zargs.Arg.optArg("jobs", ?usize).short('j').long("jobs"))
    .arg(zargs.Arg.optArg("parser_job_weight", u8).long("parser-job-weight").default(3))
    .arg(zargs.Arg.optArg("rocksdb_job_weight", u8).long("rocksdb-job-weight").default(1))
    .arg(zargs.Arg.optArg("task_queue_capacity_log2", u5).long("task-queue-capacity-log2").default(10).ranges(zargs.Ranges(u5).new().u(5, 20)));
pub fn run(self: *PrepRunner, allocator: std.mem.Allocator, last_diag: *diag.Diagnostic) !void {
    try @import("preprocess.zig").preprocess(self, allocator, last_diag);
    return;
}
pub fn initFromArgs(args: PrepRunner.cmd.Result(), allocator: std.mem.Allocator) !CliRunner {
    var building_bare_repo_path: std.ArrayList(u8) = .empty;
    errdefer building_bare_repo_path.deinit(allocator);
    if (args.bare_repo_path) |bare_repo_path| {
        try building_bare_repo_path.appendSlice(allocator, bare_repo_path);
    } else if (args.repo_path) |repo_path| {
        try building_bare_repo_path.appendSlice(allocator, repo_path);
        try building_bare_repo_path.appendSlice(allocator, "/.git");
    } else {
        std.log.err("Option `bare-repo-path` or `repo-path` is necessary.\n", .{});
        return CliRunner.Error.CliArgInvalidInput;
    }
    const n_jobs = if (args.jobs) |jobs| jobs else try std.Thread.getCpuCount();
    // 在rocksdb那边最大线程数需要使用c整数输入。提前确保它不会溢出。
    if (n_jobs > std.math.maxInt(c_int)) {
        std.log.err("Option `jobs` is set unreasonably large.\n", .{});
        return error.CliArgInvalidInput;
    }
    return .{ .prep = .{
        .global = CliRunner.Global.initGlobal(args),
        .bare_repo_path = try building_bare_repo_path.toOwnedSliceSentinel(allocator, 0),
        .rocksdb_output = try std.mem.Allocator.dupeZ(allocator, u8, args.rocksdb_output),
        .n_jobs = n_jobs,
        .task_queue_capacity_log2 = args.task_queue_capacity_log2,
    } };
}
pub fn deinit(self: *PrepRunner, allocator: std.mem.Allocator) void {
    allocator.free(self.bare_repo_path);
    self.bare_repo_path = undefined;
    allocator.free(self.rocksdb_output);
    self.rocksdb_output = undefined;
}
