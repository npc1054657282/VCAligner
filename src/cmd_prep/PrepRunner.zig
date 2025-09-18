const std = @import("std");
const zargs = @import("zargs");
const gvca = @import("gvca");
const CliRunner = gvca.cli.Runner;
const c = gvca.c_helper.c;
const diag = gvca.diag;
const Pool = gvca.Pool;
const PrepRunner = @This();
const mpsc_queue = @import("mpsc_queue");
const MpscChannel = gvca.MpscChannel;
const CommitRangesMergeOperaterState = gvca.rocksdb_custom.CommitRangesMergeOperaterState;

pub const Queue = mpsc_queue.AnyMpscQueue(Parsed, null);
pub const Channel = MpscChannel(Queue);
pub const CommitSeq = u32;
// Array hash map的`count()`返回类型为`usize`，与`hash map`的`u32`有显著不同。这是因为涉及索引，用`usize`有很大方便。
// 但实际上pathSeq只需要`u32`足矣。
pub const PathSeq = u32;
pub const PathBlobKey = extern struct {
    path_seq: PathSeq align(1),
    blob_hash: c.git_oid align(1),
};
pub const PathBlobSeq = u32;
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
rocksdb_output: [:0]u8,
tmp_output_prefix: []u8, // 生成临时文件的文件名前缀。与`rocksdb_output`在同一个父目录下，并由pid与
// 指代计算密集型任务。rocksdb的flush多为I/O密集型任务，不在`n_jobs`考虑范围内
n_jobs: usize,
n_rocksdbjobs: c_int,
task_queue_capacity_log2: u5,
compaction_trigger: c_int,
// max_allowed_space_usage: u64,
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
        for (try self.lctxs.addManyAsSlice(allocator, 1 + n_parserjobs), 0..) |*lctx, id| {
            lctx.init(channel);
            try gvca.crash_dump.reg("parser", id, &lctx.dumpable);
        }
    }
    pub fn deinit(self: *Parsers, allocator: std.mem.Allocator) void {
        for (self.lctxs.items, 0..) |*lctx, id| {
            gvca.crash_dump.unreg("parser", id);
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
    path_blob_registry: struct {
        map: std.AutoHashMapUnmanaged(PathBlobKey, PathBlobSeq) = .empty,
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
    .arg(zargs.Arg.optArg("compaction_trigger", c_int).long("compaction-trigger").default(0));
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

    const rocksdb_output, const tmp_output_prefix = blk: {
        const pid = pid: {
            // 除了windows，其他的pid都是一个整数，唯有windows的pid是一个opaque指针。
            // 此处zig的实现可能有点问题，违背了POSIX对`pid_t`的规定，此处为一个workaround，将其强转为整数。
            const pid = std.c.getpid();
            switch (@import("builtin").os.tag) {
                .windows => break :pid @intFromPtr(pid),
                else => break :pid pid,
            }
        };
        const ts = std.time.nanoTimestamp();
        // NOTE：父目录解析为`null`存在一个合法可能：`rocksdb_output`只有名字。此时父目录解析为`null`意味着父目录为当前目录。
        // 其它情况下解析为`null`的情况，不论是`rocksdb_output`是当前目录，或者是一个盘符都是非法的。
        // 这种情况将在`rocksdb`创建数据库的时候报告错误，因此此处不再检查。
        const maybe_parent_dir: ?[]const u8 = if (args.rocksdb_output) |rocksdb_output| std.fs.path.dirname(rocksdb_output) else "tmp";
        // 检查父目录是否存在。若不存在，创建之。
        if (maybe_parent_dir) |parent_dir| {
            const cwd = std.fs.cwd();
            cwd.access(parent_dir, .{}) catch |access_err| {
                switch (access_err) {
                    error.FileNotFound => cwd.makeDir(parent_dir) catch |mkdir_err| {
                        switch (mkdir_err) {
                            // 考虑多进程竞争场景，可能存在同进程已经创建目录的情形。此时是安全的。
                            error.PathAlreadyExists => {},
                            else => return mkdir_err,
                        }
                    },
                    else => return access_err,
                }
            };
        }
        var tmp_output_prefix_writer = std.Io.Writer.Allocating.init(allocator);
        try tmp_output_prefix_writer.writer.print("{s}/{d}-{d}-", .{
            maybe_parent_dir orelse ".",
            pid,
            ts,
        });
        const tmp_output_prefix = try tmp_output_prefix_writer.toOwnedSlice();
        errdefer allocator.free(tmp_output_prefix);
        const rocksdb_output = rocksdb_output: {
            if (args.rocksdb_output) |rocksdb_output| break :rocksdb_output try allocator.dupeZ(u8, rocksdb_output);
            var rocksdb_output_builder: std.ArrayList(u8) = .empty;
            try rocksdb_output_builder.appendSlice(allocator, tmp_output_prefix);
            try rocksdb_output_builder.appendSlice(allocator, "rocksdb-output");
            break :rocksdb_output try rocksdb_output_builder.toOwnedSliceSentinel(allocator, 0);
        };
        errdefer allocator.free(rocksdb_output);
        break :blk .{ rocksdb_output, tmp_output_prefix };
    };
    errdefer {
        allocator.free(rocksdb_output);
        allocator.free(tmp_output_prefix);
    }

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
            .rocksdb_output = rocksdb_output,
            .tmp_output_prefix = tmp_output_prefix,
            .n_jobs = n_jobs,
            .n_rocksdbjobs = n_rocksdbjobs,
            .task_queue_capacity_log2 = args.task_queue_capacity_log2,
            .compaction_trigger = args.compaction_trigger,
            // .max_allowed_space_usage = args.max_allowed_space_usage,
        },
    };
}
pub fn deinit(self: *PrepRunner, allocator: std.mem.Allocator) void {
    allocator.free(self.bare_repo_path);
    self.bare_repo_path = undefined;
    allocator.free(self.rocksdb_output);
    self.rocksdb_output = undefined;
    allocator.free(self.tmp_output_prefix);
    self.tmp_output_prefix = undefined;
}
