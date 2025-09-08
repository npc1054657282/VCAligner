const std = @import("std");
const zargs = @import("zargs");
const CliRunner = @import("gvca").cli.Runner;
const c = @import("gvca").c_helper.c;
const diag = @import("gvca").diag;
const Pool = @import("gvca").Pool;
const PrepRunner = @This();
const mpsc_queue = @import("mpsc_queue");
const MpscChannel = @import("gvca").MpscChannel;
const FixedBinaryAppendMergeOperaterState = @import("gvca").rocksdb_custom.FixedBinaryAppendMergeOperaterState;

pub const Queue = mpsc_queue.AnyMpscQueue(Parsed, null);
pub const Channel = MpscChannel(Queue);
const CommitRegistryTable = std.AutoHashMapUnmanaged(c.git_oid, void);
pub const CommitSeq = CommitRegistryTable.Size;
// Array hash map的`count()`返回类型为`usize`，与`hash map`的`u32`有显著不同。这是因为涉及索引，用`usize`有很大方便。
// 尽管path多数情况下最大值可能不如commit多。简单起见PathSeq设置为符合ArrayHashMap要求的usize。
pub const PathSeq = usize;
pub const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    commit_hash: ?c.git_oid,
    commit_seq: *CommitSeq,
    // XXX: 考虑`MultiArrayList`，但是实际使用有些困难，因为实际上我的需求是要为key与path本身设计列表，也要为key的指针设计列表。
    // 如果`MultiArrayList`的各个成员之间有地址依赖，该怎么设计，我感到头疼。因此目前依然是设计为分开的`ArrayList`
    // 可能并非必要，因为已经在arena中分配？
    // path_strings: std.ArrayList(u8),
    parsed_units: std.ArrayList(ParsedUnit),
    keys_list: std.ArrayList(*KeyBuf),
    // 将CommitSeq的指针一次性拷贝len次
    values_list: []*CommitSeq,
    pub const KeyBuf = extern struct {
        path_seq: PathSeq align(1), // flush时未赋值，写入前解析赋值。
        blob_hash: [20]u8 align(1), //目前硬编码，尚未考虑SHA256。未来libgit2升级了可能会考虑。
    };
    pub const ParsedUnit = struct {
        path: []u8,
        key: KeyBuf,
    };
};

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
    pool: Pool,
    wait_group: std.Thread.WaitGroup,
    lctxs: std.ArrayListAligned(@import("parse.zig").Parsing, std.mem.Alignment.fromByteUnits(std.atomic.cache_line)),
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
    table: CommitRegistryTable = .empty,
    arena: std.heap.ArenaAllocator,
} align(std.atomic.cache_line) = undefined,
// 下列内容是写线程会修改，而最终移交给主线程的内容。
writer: struct {
    path_registry: struct {
        // ArrayHashMap提供排序功能，应当使用它
        map: std.StringArrayHashMapUnmanaged(struct {
            // 初次插入时的index。插入同时记录，因为后续排序时，原始index会丢失
            index: PathSeq,
            // 在写入过程中不记录此值。在全部写入完毕以后，遍历一遍所有的key统计此值。最后排序的依据。
            // XXX: 在内存中为每个path都记录一个它的blob的hashmap。怀疑其可行性，宁肯全部写入完毕以后再遍历rocksdb数据库。
            blob_cnt: usize,
        }) = .empty,
        // arena很重要，注意`StringArrayHashMapUnmanaged`不会拷贝键，因此键需要自己手动拷贝保存
        //因此arena不仅负责`StringArrayHashMapUnmanaged`，还负责键的保存。
        arena: std.heap.ArenaAllocator,
    },
    merge_operator_state: FixedBinaryAppendMergeOperaterState,
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
