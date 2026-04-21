const std = @import("std");
const zargs = @import("zargs");
const vcaligner = @import("vcaligner");
const CliRunner = vcaligner.cli.Runner;
const c = vcaligner.c_helper.c;
const diag = vcaligner.diag;
const Pool = vcaligner.Pool;
const PrepRunner = @This();
const mpsc_queue = @import("mpsc_queue");
const MpscChannel = vcaligner.MpscChannel;
const CommitSeq = vcaligner.rocksdb_custom.CommitSeq;
const PathSeq = vcaligner.rocksdb_custom.PathSeq;
const BlobPathKey = vcaligner.rocksdb_custom.BlobPathKey;
const BlobPathSeq = vcaligner.rocksdb_custom.BlobPathSeq;
const Key = vcaligner.rocksdb_custom.Key;

pub const Queue = mpsc_queue.AnyMpscQueue(Parsed, null);
pub const Channel = MpscChannel(Queue);
pub const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    commit_seq: CommitSeq,
    // XXX: 考虑`MultiArrayList`，但是实际使用有些困难，因为实际上我的需求是要为key与path本身设计列表，也要为key的指针设计列表。
    // 如果`MultiArrayList`的各个成员之间有地址依赖，该怎么设计，我感到头疼。因此目前依然是设计为分开的`ArrayList`
    // 可能并非必要，因为已经在arena中分配？
    // path_strings: std.ArrayList(u8),
    parsed_units: std.ArrayList(ParsedUnit),
    pub const ParsedUnit = struct {
        path: []u8,
        blob_hash: c.git_oid,
    };
};

global: CliRunner.Global,
bare_repo_path: [:0]u8,
rocksdb_output: union(enum) {
    manual: [:0]u8,
    auto: [:0]u8,
    // 内容仅包含堆上的切片，即指针，不需要使用`*This()`，值传递是安全的。
    pub fn get(self: @This()) [:0]u8 {
        return switch (self) {
            .manual => self.manual,
            .auto => self.auto,
        };
    }
},
// 指代计算密集型任务。rocksdb的flush多为I/O密集型任务，不在`n_jobs`考虑范围内
n_jobs: usize,
n_rocksdbjobs: c_int,
task_queue_capacity_log2: u5,
compaction_trigger: c_int,
compression: bool,
// 采集本进程的pid与一个时间戳，用于生成本进程唯一信息，可用于临时文件命名。
proc_stamp: struct {
    pid: vcaligner.pid.Pid,
    ts: i128,
},
// max_allowed_space_usage: u64,
repo: *c.git_repository = undefined,
odb: *c.git_odb = undefined,
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
        for (try self.lctxs.addManyAsSlice(allocator, 1 + n_parserjobs), 0..) |*lctx, id| {
            lctx.init(channel);
            try vcaligner.crash_dump.reg("parser", id, &lctx.dumpable);
        }
    }
    pub fn deinit(self: *Parsers, allocator: std.mem.Allocator) void {
        for (self.lctxs.items, 0..) |*lctx, id| {
            vcaligner.crash_dump.unreg("parser", id);
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
    // 目前需求：查找频繁，最后迭代一次。迭代是无序的。
    // 目前基于最高查询效率的目的采用HashMap。未来或考虑array hash map。
    map: std.AutoHashMapUnmanaged(c.git_oid, CommitSeq) = .empty,
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
            // 实际使用`rocksdb_approximate_sizes_cf`获取，因此是约数。
            // XXX: 在内存中为每个path都记录一个它的blob的hashmap。怀疑其可行性，宁肯全部写入完毕以后再遍历rocksdb数据库。
            blob_cnt: usize,
        }) = .empty,
        // arena很重要，注意`StringArrayHashMapUnmanaged`不会拷贝键，因此键需要自己手动拷贝保存
        //因此arena不仅负责`StringArrayHashMapUnmanaged`，还负责键的保存。
        arena: std.heap.ArenaAllocator,
    },
    blob_path_registry: struct {
        map: std.AutoHashMapUnmanaged(BlobPathKey, BlobPathSeq) = .empty,
        arena: std.heap.ArenaAllocator,
    },
    // merge_operator_state: CommitRangesMergeOperaterState,
} align(std.atomic.cache_line) = undefined,

pub const cmd = CliRunner.Global.sharedArgs(zargs.Command.new("prep"))
    .arg(zargs.Arg.optArg("repo_path", ?[]const u8).long("repo-path"))
    .arg(zargs.Arg.optArg("bare_repo_path", ?[]const u8).long("bare-repo-path"))
    .arg(zargs.Arg.optArg("rocksdb_output", ?[]const u8).long("rocksdb-output").short('o'))
    .arg(zargs.Arg.optArg("jobs", ?usize).short('j').long("jobs"))
    .arg(zargs.Arg.optArg("rocksdb_job_weight", f32).long("rocksdb-job-weight").default(0.5))
    .arg(zargs.Arg.optArg("task_queue_capacity_log2", u5).long("task-queue-capacity-log2").default(8).ranges(zargs.Ranges(u5).new().u(5, 20)))
    // 0指代禁用自动compaction。
    .arg(zargs.Arg.optArg("compaction_trigger", c_int).long("compaction-trigger").default(0))
    // 缺省启用compression。手动设置no-compression才能关闭。这是因为经过测试，compression可以将最终rocksdb的大小缩减到无压缩的1/3，且性能不降反升。
    // 性能提升的原因应该在于随着rocksdb的大小降低，I/O降低。
    .arg(zargs.Arg.opt("no_compression", bool).long("no-compression"));
pub fn run(self: *PrepRunner, allocator: std.mem.Allocator, last_diag: *diag.Diagnostic) !void {
    try @import("preprocess.zig").preprocess(self, allocator, last_diag);
    return;
}
pub fn initFromArgs(args: PrepRunner.cmd.Result(), allocator: std.mem.Allocator) !CliRunner {
    const bare_repo_path: [:0]u8 = blk: {
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
        break :blk try building_bare_repo_path.toOwnedSliceSentinel(allocator, 0);
    };
    errdefer allocator.free(bare_repo_path);

    const n_jobs = if (args.jobs) |jobs| jobs else try std.Thread.getCpuCount();
    // 在rocksdb那边最大线程数需要使用c整数输入。提前确保它不会溢出。
    const n_rocksdbjobs: c_int = blk: {
        const n_rocksdbjobs: f32 = @as(f32, @floatFromInt(n_jobs)) * args.rocksdb_job_weight;
        if (!std.math.isFinite(n_rocksdbjobs) or n_rocksdbjobs > @as(f32, @floatFromInt(std.math.maxInt(c_int)))) {
            std.log.err("Option `jobs` or `rocksdb-job-weight` is set unreasonably large.\n", .{});
            return error.CliArgInvalidInput;
        }
        break :blk @intFromFloat(n_rocksdbjobs);
    };
    return .{
        .prep = .{
            .global = CliRunner.Global.initGlobal(args),
            .bare_repo_path = bare_repo_path,
            .rocksdb_output = if (args.rocksdb_output) |rocksdb_output| .{
                .manual = try allocator.dupeZ(u8, rocksdb_output),
            } else .{ .auto = undefined },
            .n_jobs = n_jobs,
            .n_rocksdbjobs = n_rocksdbjobs,
            .task_queue_capacity_log2 = args.task_queue_capacity_log2,
            .compaction_trigger = args.compaction_trigger,
            .compression = !args.no_compression,
            .proc_stamp = .{
                .pid = vcaligner.pid.get(),
                .ts = std.time.nanoTimestamp(),
            },
            // .max_allowed_space_usage = args.max_allowed_space_usage,
        },
    };
}
pub fn deinit(self: *PrepRunner, allocator: std.mem.Allocator) void {
    allocator.free(self.bare_repo_path);
    switch (self.rocksdb_output) {
        .manual => allocator.free(self.rocksdb_output.manual),
        .auto => {},
    }
    self.* = undefined;
}
