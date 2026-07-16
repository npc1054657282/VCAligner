const std = @import("std");
const zargs = @import("zargs");
const vcaligner = @import("vcaligner");
const diag = vcaligner.diag;
const cli = vcaligner.cli;
const PrepRunner = @This();

pub const Mode = enum { full, incremental };
pub const CompactionStrategy = union(enum) {
    // 写入时不自动压缩，写入全结束后额外进行一次自动压缩
    manual_delayed: void,
    // 设定触发器的自动压缩
    auto_with_trigger: c_int,
    // 默认自动压缩
    auto_default: void,
};

// 重构后的PrepRunner：仅包含不可变的配置信息，任何可变项修改为到了解析时随着需求构造而非放到PrepRunner里。
global: cli.Runner.Global,
bare_repo_path: [:0]u8,
mode_conf: union(Mode) {
    full: struct {
        rocksdb_output: union(enum) { manual: [:0]u8, auto: void },
        compaction_strategy: CompactionStrategy,
    },
    incremental: struct {
        rocksdb_output: [:0]u8,
        // XXX: 强行将其与父类型的具体枚举值对齐可能是没有必要的。
        compaction_strategy: union(enum(std.meta.Tag(std.meta.Tag(CompactionStrategy)))) {
            auto_with_trigger: c_int = @intFromEnum(std.meta.Tag(CompactionStrategy).auto_with_trigger),
            auto_default: void = @intFromEnum(std.meta.Tag(CompactionStrategy).auto_default),
            pub fn asParent(self: @This()) CompactionStrategy {
                return switch (self) {
                    inline else => |v, tag| @unionInit(CompactionStrategy, @tagName(tag), v),
                };
            }
        },
    },
    pub fn deinit(noalias self: *const @This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            // 存在捕获`full_conf`和`*full_conf`两种选择。选择了前者，因为实际上它们的大小差距不是很悬殊，后者也可能让人误解这是一个有状态的量。
            .full => |full_conf| switch (full_conf.rocksdb_output) {
                .manual => |path| allocator.free(path),
                .auto => {},
            },
            .incremental => |inc_conf| allocator.free(inc_conf.rocksdb_output),
        }
    }
    pub fn compactionStrategy(noalias self: *const @This()) CompactionStrategy {
        return switch (self.*) {
            .full => |full_conf| full_conf.compaction_strategy,
            .incremental => |inc_conf| inc_conf.compaction_strategy.asParent(),
        };
    }
},
// 指代计算密集型任务。rocksdb的flush多为I/O密集型任务，不在`n_jobs`考虑范围内
n_jobs: usize,
n_rocksdbjobs: c_int,
default_cf_max_write_buffer_number: c_int,
parsed_queue_capacity_log2: u5,
compression: bool,
writebatch_watermark: c_int,
// 采集本进程的pid与一个时间戳，用于生成本进程唯一信息，可用于临时文件命名。
// XXX: 未来可能移动至cli.Runner.Global，但目前的ana确实无此需求。
proc_stamp: struct {
    pid: vcaligner.pid.Pid,
    ts: i128,
},

// 增量需启用`-i`或`--increment`参数。如果使用此参数，必须添加`rocksdb-output`参数，此参数既是输出，也是上一次的rocksdb生成结果。
// 启动增量时，总是基于上一次的rocksdb结果继续补充数据，而不支持“另存为”操作；
// 如果有此需求，进程调用者应该事先备份rocksdb数据库，然后使用备份后的数据库作为`rocksdb-ouput`参数。
const cmd_config: cli.CommandConfig = cli.Runner.cmd_config;
pub const cmd = blk: {
    @setEvalBranchQuota(2048);
    break :blk cli.Runner.Global.sharedArgs(zargs.Command.new("increprep"))
        // 待预处理的git仓库路径。要求此路径下包含一个`.git`目录。此选项与`bare-repo-path`至少需要提供一个。如果有`bare-repo-path`参数，此选项被无视。
        .arg(zargs.Arg.optArg("repo_path", ?[]const u8).long("repo-path").help(
            \\Path to the target Git repository (must contain a .git directory). 
        ++ vcaligner.cli.helpNewLine(cmd_config) ++
            \\Ignored if --bare-repo-path is provided.
        ++ vcaligner.cli.helpLastLine(cmd_config) ++
            \\
        ))
        // 待预处理的git裸仓库路径。此选项与`repo-path`至少需要提供一个。覆盖`repo-path`。
        .arg(zargs.Arg.optArg("bare_repo_path", ?[]const u8).long("bare-repo-path").help(
            \\Path to the target bare Git repository.
        ++ vcaligner.cli.helpNewLine(cmd_config) ++
            \\Overrides --repo-path.
        ++ vcaligner.cli.helpLastLine(cmd_config) ++
            \\
        ))
        // 启用增量模式（基于已经解析过的预处理rocksdb数据库进行增量解析）。不提供此选项，则启用全量模式。
        .arg(zargs.Arg.optArg("increment", bool).short('i').long("increment").help(
            \\Enable incremental parsing mode. 
        ++ vcaligner.cli.helpNewLine(cmd_config) ++
            \\Must be used with an existing database via --rocksdb-output.
        ++ vcaligner.cli.helpLastLine(cmd_config) ++
            \\
        ))
        // 指定git仓库被解析到的rocksdb仓库路径。对于增量模式，此选项必须，且必须是一个已经存在的与指定的git仓库匹配的rocksdb数据库。
        // TODO: 当前尚无检验增量指定的git仓库是否和rocksdb数据库匹配的逻辑。实现困难的原因之一是当前判定repo-id的逻辑不完善。未来理应实现。
        // 对于全量模式，此选项非必须，如指定，必须是一个不存在rocksdb数据库的路径。如不指定，会基于本进程信息自动构造rocksdb仓库路径。
        // XXX: 或许可以移除rocksdb_output的自动构造功能，必须强制指定此参数？
        .arg(zargs.Arg.optArg("rocksdb_output", ?[]const u8).short('o').long("rocksdb-output").help(
            \\Output directory for the RocksDB database.
        ++ cli.helpNewLine(cmd_config) ++
            \\Required and must exist for incremental mode.
        ++ cli.helpLastLine(cmd_config) ++
            \\
        ))
        // 为vcaligner的主要解析逻辑的工作线程数量。不包含rocksdb的flush磁盘等行为所使用的线程。
        .arg(zargs.Arg.optArg("jobs", ?usize).short('j').long("jobs").help(
            \\Number of parser worker threads. 
        ++ cli.helpNewLine(cmd_config) ++
            \\(Note: Does not include RocksDB background I/O threads).
        ++ cli.helpLastLine(cmd_config) ++
            \\
        ))
        // rocksdb的工作线程权重，为rocksdb分配的线程数量是`jobs`参数与此权重的乘积。
        .arg(zargs.Arg.optArg("rocksdb_job_weight", f32).long("rocksdb-job-weight").default(0.5).help(
            \\Number of main worker threads for parsing and coordination.
        ++ cli.helpNewLine(cmd_config) ++
            \\(Note: Does not include RocksDB background I/O threads)
        ++ cli.helpLastLine(cmd_config) ++
            \\
        ))
        // 影响rocksdb的核心列族的写缓存数量的因数，通过与rocksdb工作线程数量相乘决定写缓存数量。
        // 写缓存数量存在一个缺省下限，因此如果将次比例调得极低，就相当于将写缓存数量设置为缺省下限。
        .arg(zargs.Arg.optArg("max_write_buffers_factor", f32).long("max-write-buffers-factor").default(1.0).help(
            \\Factor used to determine the maximum number of write buffers for the primary column family
        ++ cli.helpNewLine(cmd_config) ++
            \\by multiplying with the RocksDB thread count. 
        ++ cli.helpNewLine(cmd_config) ++
            \\A minimum safety limit is enforced.
        ++ cli.helpLastLine(cmd_config) ++
            \\
        ))
        // vcaligner的解析工作通过环形缓冲区实现，这同样意味着vcaligner的解析内容的缓存。此选项为解析缓存数据的容量的底数。
        .arg(zargs.Arg.optArg("parsed_queue_capacity_log2", u5).long("parsed-queue-capacity-log2").default(8).ranges(zargs.Ranges(u5).new().u(5, 20)).help(
            \\Base-2 logarithm of the parser's ring buffer capacity. 
        ++ cli.helpNewLine(cmd_config) ++
            \\This determines the maximum amount of parsed data cached in memory.
        ++ cli.helpLastLine(cmd_config) ++
            \\
        ))
        // `null`在全量模式下指代延迟compaction，在增量模式下指代自动默认compaction
        // 显式输入`default`或者0，指代显式设置自动默认compaction。其他数字指代设置compaction trigger值。
        .arg(zargs.Arg.optArg("auto_compaction", ?enum(c_int) {
            default = 0,
            _,
            pub fn parse(s: @import("ztype").String, _: ?std.mem.Allocator) ?@This() {
                if (std.ascii.eqlIgnoreCase(s, "default")) return .default;
                const compaction_trigger: c_int = std.fmt.parseInt(c_int, s, 10) catch return null;
                return @enumFromInt(compaction_trigger);
            }
        }).long("auto-compaction").help(
            \\Configure auto-compaction. 
        ++ cli.helpNewLine(cmd_config) ++
            \\Use 'default' (or 0) for standard auto-compaction, 
        ++ cli.helpNewLine(cmd_config) ++
            \\or a non-zero integer for a specific L0 trigger threshold 
        ++ cli.helpNewLine(cmd_config) ++
            \\(negative values disable L0 file triggers). 
        ++ cli.helpNewLine(cmd_config) ++
            \\Omit to use the run-mode default (delayed for full mode, 
        ++ cli.helpNewLine(cmd_config) ++
            \\auto for incremental mode).
        ++ cli.helpLastLine(cmd_config) ++
            \\
        ))
        // 缺省启用compression。手动设置no-compression才能关闭。这是因为经过测试，compression可以将最终rocksdb的大小缩减到无压缩的1/3，且性能不降反升。
        // 性能提升的原因应该在于随着rocksdb的大小降低，I/O降低。
        // 此选项禁用compression。不推荐此选项。
        .arg(zargs.Arg.opt("no_compression", bool).long("no-compression").help(
            \\Disable RocksDB block compression (LZ4). 
        ++ cli.helpNewLine(cmd_config) ++
            \\Not recommended as compression typically improves both storage size and I/O performance.
        ++ cli.helpLastLine(cmd_config) ++
            \\
        ))
        .arg(zargs.Arg.optArg("writebatch_watermark", c_int).long("writebatch-watermark").default(65536).help(
            \\Sets the threshold for flushing pending records to RocksDB.
        ++ cli.helpNewLine(cmd_config) ++
            \\Higher values reduce lock contention and commit frequency,
        ++ cli.helpLastLine(cmd_config) ++
            \\at the cost of slightly higher memory usage.
        ++ cli.helpLastLine(cmd_config) ++
            \\
        ))
        .config(cmd_config);
};

pub fn run(noalias self: *const PrepRunner, gpa: vcaligner.Gpa, last_diag: *diag.Diagnostic) !void {
    try @import("preprocess.zig").preprocess(self, gpa, last_diag);
    return;
}
pub fn initFromArgs(args: PrepRunner.cmd.Result(), allocator: std.mem.Allocator) !cli.Runner {
    const bare_repo_path: [:0]u8 = blk: {
        if (args.bare_repo_path) |bare_repo_path| break :blk try allocator.dupeZ(u8, bare_repo_path);
        if (args.repo_path) |repo_path| break :blk try std.fmt.allocPrintSentinel(allocator, "{s}/.git", .{repo_path}, 0);
        std.log.err("Option `bare-repo-path` or `repo-path` is necessary.\n", .{});
        return cli.Runner.Error.CliArgInvalidInput;
    };
    errdefer allocator.free(bare_repo_path);
    const ModeConf = @FieldType(PrepRunner, "mode_conf");
    const mode_conf: ModeConf = if (args.increment) blk: {
        const rocksdb_output = if (args.rocksdb_output) |rocksdb_output| try allocator.dupeZ(u8, rocksdb_output) else {
            std.log.err("Option `bare-repo-path` or `repo-path` is necessary.\n", .{});
            return cli.Runner.Error.CliArgInvalidInput;
        };
        errdefer comptime unreachable;
        break :blk .{ .incremental = .{
            .rocksdb_output = rocksdb_output,
            .compaction_strategy = if (args.auto_compaction) |auto_compaction| switch (auto_compaction) {
                .default => .auto_default,
                _ => |trigger_tag| .{ .auto_with_trigger = @intFromEnum(trigger_tag) },
            } else .auto_default,
        } };
    } else blk: {
        const rocksdb_output: @FieldType(@FieldType(ModeConf, "full"), "rocksdb_output") =
            if (args.rocksdb_output) |rocksdb_output| .{ .manual = try allocator.dupeZ(u8, rocksdb_output) } else .auto;
        errdefer comptime unreachable;
        break :blk .{ .full = .{
            .rocksdb_output = rocksdb_output,
            .compaction_strategy = if (args.auto_compaction) |auto_compaction| switch (auto_compaction) {
                .default => .auto_default,
                _ => |trigger_tag| .{ .auto_with_trigger = @intFromEnum(trigger_tag) },
            } else .manual_delayed,
        } };
    };
    errdefer mode_conf.deinit(allocator);
    const n_jobs = if (args.jobs) |jobs| jobs else try std.Thread.getCpuCount();
    const n_rocksdbjobs: c_int = blk: {
        const n_rocksdbjobs: f32 = @as(f32, @floatFromInt(n_jobs)) * args.rocksdb_job_weight;
        if (!std.math.isFinite(n_rocksdbjobs) or n_rocksdbjobs > @as(f32, @floatFromInt(std.math.maxInt(c_int)))) {
            std.log.err("Option `jobs` or `rocksdb-job-weight` is set unreasonably.\n", .{});
            return error.CliArgInvalidInput;
        }
        // `rocksdbjobs`的最小保护线程为4。这个值出自rocksdb的`PrepareForBulkLoad`内部实现中，flush最大线程的设定值。
        // 至少在非自动compaction场景下，我们不希望我们的配置值比`PrepareForBulkLoad`的默认flush线程还要低。
        // `PrepareForBulkLoad`还设置了compaction最大线程值为2。但这只是`PrepareForBulkLoad`的一个hack，
        // 因为把compaction的最大线程值足够小，rocksdb有可能写入的时候直接写到L1而非L0，所以设置了这个hack值。
        // 但是实际上我们根本不compaction，所以这个设定值不会影响真实的最大rocksdb的工作线程。
        // 上述论述并没有考虑自动compaction场景。在自动compaction场景，4这个值依然是一个合理的rocksdb工作线程最小值。
        break :blk if (n_rocksdbjobs < 4) 4 else @intFromFloat(@trunc(n_rocksdbjobs));
    };
    const default_cf_max_write_buffer_number: c_int = blk: {
        const default_cf_max_write_buffer_number: f32 = @as(f32, @floatFromInt(n_rocksdbjobs)) * args.max_write_buffers_factor;
        if (!std.math.isFinite(default_cf_max_write_buffer_number) or default_cf_max_write_buffer_number > @as(f32, @floatFromInt(std.math.maxInt(c_int)))) {
            std.log.err("Option `max-write-buffers-factor` is set unreasonably.\n", .{});
            return error.CliArgInvalidInput;
        }
        // 默认列族的写缓冲数量最小保护值为6。这个值依旧出自`PrepareForBulkLoad`内部实现。
        // 对于自动compaction这个最小值虽然偏大，但是默认列族比其他列族的缓冲数量要多一些是合理的。这个设置大了仅仅是多消耗一点内存，问题不大。
        break :blk if (default_cf_max_write_buffer_number < 6) 6 else @intFromFloat(@trunc(default_cf_max_write_buffer_number));
    };
    return .{ .increprep = .{
        .global = .init(args),
        .bare_repo_path = bare_repo_path,
        .mode_conf = mode_conf,
        .n_jobs = n_jobs,
        .n_rocksdbjobs = n_rocksdbjobs,
        .default_cf_max_write_buffer_number = default_cf_max_write_buffer_number,
        .parsed_queue_capacity_log2 = args.parsed_queue_capacity_log2,
        .compression = !args.no_compression,
        .writebatch_watermark = args.writebatch_watermark,
        .proc_stamp = .{
            .pid = vcaligner.pid.get(),
            .ts = std.time.nanoTimestamp(),
        },
    } };
}

pub fn deinit(noalias self: *const PrepRunner, allocator: std.mem.Allocator) void {
    allocator.free(self.bare_repo_path);
    self.mode_conf.deinit(allocator);
}
