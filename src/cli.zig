const std = @import("std");
const zargs = @import("zargs");
pub const Runner = union(enum) {
    prep: @import("prep/prep_cli.zig").PrepRunner,
    const cmd = cmd_blk: {
        var building_cmd = zargs.Command.new("gvca").requireSub("sub")
            .about("git version commit aligner")
            .version("0.0.0")
            .author("npc1054657282");
        for (@typeInfo(Runner).@"union".fields) |field| {
            building_cmd = building_cmd.sub(field.type.cmd);
        }
        break :cmd_blk building_cmd;
    };
    pub const Global = struct {
        verbose: bool,
        // 为子命令添加全局共享参数。不是指那种必须在子命令前输入的全局参数，我不打算使用此类参数。此处是每个子命令都会指定重复添加的参数。
        pub fn sharedArgs(sub_cmd: zargs.Command) zargs.Command {
            return sub_cmd.arg(zargs.Arg.opt("verbose", bool).short('v').long("verbose"));
        }
        pub fn initGlobal(args: anytype) Global {
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
                return try @FieldType(Runner, @tagName(subtag)).initFromArgs(subarg, allocator);
            },
        }
    }
    pub fn deinit(self: *Runner, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*case| return case.deinit(allocator),
        }
    }
    pub fn run(self: *Runner) !void {
        switch (self.*) {
            inline else => |*case| return case.run(),
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
    const args = cmd.parse(allocator) catch |e|
        zargs.exitf(e, 1, "\n{s}\n", .{cmd.usage()});
    defer cmd.destroy(&args, allocator);
    var runner: Runner = undefined;
    runner = try Runner.initFromArgs(args, allocator);
    return runner;
}
