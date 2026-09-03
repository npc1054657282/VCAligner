const std = @import("std");
const zargs = @import("zargs");
const vcaligner = @import("vcaligner");
const diag = vcaligner.diag;

pub const PrepRunner = @import("cmd_prep/PrepRunner.zig");
pub const ana_runner = @import("cmd_ana/ana_runner.zig");

// 解耦：不是所有的Runner都附带子命令定义，而是引入runner dispatcher的概念。
// 无需分发的dispatcher和其唯一的Runner是一体的，而需要分发的则加入了独立层。
const sub_cmd_runner_dispatchers = [_]type{
    PrepRunner,
    ana_runner,
};

const sub_cmd_name_to_runner_dispatcher_map: std.StaticStringMap(type) = blk: {
    const entries = entries: {
        var arr: [sub_cmd_runner_dispatchers.len]struct { []const u8, type } = undefined;
        for (sub_cmd_runner_dispatchers, 0..) |T, i| {
            const key = @field(T, "sub_cmd_name");
            arr[i] = .{ key, T };
        }
        break :entries arr;
    };
    break :blk .initComptime(&entries);
};
pub const Runner = union(enum) {
    prep: PrepRunner,
    ana_topology: ana_runner.Topology,
    ana_strict: ana_runner.Strict,
    pub const cmd_config: CommandConfig = .{};
    const cmd = blk: {
        var building_cmd = zargs.Command.new("vcaligner").requireSub("sub")
            .about("git version commit aligner")
            .version("0.2.0")
            .author("npc1054657282");
        for (sub_cmd_runner_dispatchers) |SubCmdRunnerDispatcher| {
            building_cmd = building_cmd.sub(SubCmdRunnerDispatcher.cmd);
        }
        break :blk building_cmd.config(cmd_config);
    };
    pub const Global = struct {
        verbose: bool,
        // 为子命令添加全局共享参数。不是指那种必须在子命令前输入的全局参数，我不打算使用此类参数。此处是每个子命令都会指定重复添加的参数。
        pub fn sharedArgs(sub_cmd: zargs.Command) zargs.Command {
            return sub_cmd.arg(zargs.Arg.opt("verbose", bool).short('v').long("verbose"));
        }
        pub fn init(args: anytype) Global {
            comptime std.debug.assert(@hasField(@TypeOf(args), "verbose"));
            return .{
                .verbose = args.verbose,
            };
        }
    };
    pub fn initFromArgs(args: Runner.cmd.Result(), allocator: std.mem.Allocator) !Runner {
        // 这里可以插入处理全局参数。但目前我的范式是不使用名义上的全局参数，而是将全局参数变为所有子命令都共同使用一份的“共享参数”
        // 因此这块全局参数的处理逻辑不实现。
        switch (args.sub) {
            inline else => |subarg, subtag| {
                return try sub_cmd_name_to_runner_dispatcher_map.get(@tagName(subtag)).?.initFromArgs(subarg, allocator);
            },
        }
    }
    pub fn deinit(self: *Runner, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*case| return case.deinit(allocator),
        }
    }
    /// NOTE: allocator必须线程安全
    pub fn run(self: *Runner, gpa: vcaligner.gpa.Concurrent, last_diag: *diag.Diagnostic) !void {
        switch (self.*) {
            inline else => |*case| return case.run(gpa, last_diag),
        }
    }
    pub const Error = error{
        CliArgInvalidInput,
    };
};

// 为什么不在main里直接解析cli，而要多此一举用一个函数呢？
// 主要原因是zargs会自动创建一个解析结果，我们不希望这个解析结果占用整个程序的生命周期。
// 因此，将它包装在一个函数里，将解析结果转化为一个执行器，这样这个解析结果的生命周期就可以在执行完以后提前结束了。
pub fn parseArgs(allocator: std.mem.Allocator) !Runner {
    const cmd = Runner.cmd;
    var args = cmd.parse(allocator) catch |e|
        zargs.exitf(e, 1, "\n{s}\n", .{cmd.usageString()});
    defer cmd.destroy(&args, allocator);
    var runner: Runner = undefined;
    runner = try Runner.initFromArgs(args, allocator);
    return runner;
}

const ztype = @import("ztype");
pub const CommandConfig = @typeInfo(@TypeOf(zargs.Command.config)).@"fn".params[1].type.?;
pub fn helpNewLine(comptime cmd_conf: CommandConfig) ztype.LiteralString {
    return comptime ret: {
        var ret: [:0]const u8 =
            \\
            \\
        ;
        for (0..cmd_conf.format.left_max + cmd_conf.format.indent) |_| ret = ret ++ " ";
        break :ret ret;
    };
}
pub fn helpLastLine(comptime cmd_conf: CommandConfig) ztype.LiteralString {
    return comptime ret: {
        var ret: [:0]const u8 =
            \\
            \\
        ;
        for (0..cmd_conf.format.left_max + cmd_conf.format.indent - 1) |_| ret = ret ++ " ";
        break :ret ret;
    };
}
