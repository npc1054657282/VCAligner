const std = @import("std");
const zargs = @import("zargs");
pub const Runner = union(enum) {
    prep: @import("prep/prep_cli.zig").Prep,
    pub fn run(self: *@This()) !void {
        switch (self.*) {
            inline else => |*case| return case.run(),
        }
    }
    pub fn getCmd() zargs.Command {
        comptime var cmd = zargs.Command.new("gvca").requireSub("sub")
            .about("git version commit aligner")
            .version("0.0.0")
            .author("npc1054657282");
        inline for (@typeInfo(Runner).@"union".fields) |field| {
            cmd = cmd.sub(field.type.getCmd());
        }
        return cmd;
    }
    // 全局共享参数。不是指那种必须在子命令前输入的参数，我不打算使用此类参数。此处是每个子命令都会指定重复添加的参数。
    pub fn sharedArgs(cmd: zargs.Command) zargs.Command {
        return cmd.arg(zargs.Arg.opt("verbose", bool).short('v').long("verbose"));
    }
    pub fn initFromArgs(args: @This().getCmd().Result(), allocator: std.mem.Allocator) @This() {
        // 这里可以插入处理全局参数。但目前我的范式是不使用名义上的全局参数，而是将全局参数变为所有子命令都共同使用一份的“共享参数”
        // 因此这块全局参数的处理逻辑不实现。
        switch (args.sub) {
            inline else => |subarg, subtag| {
                return @FieldType(@This(), @tagName(subtag)).initFromArgs(subarg, allocator);
            },
        }
    }
};

// 为什么不在main里直接解析cli，而要多此一举用一个函数呢？
// 主要原因是zargs会自动创建一个解析结果，我们不希望这个解析结果占用整个程序的生命周期。
// 因此，将它包装在一个函数里，将解析结果转化为一个执行器，这样这个解析结果的生命周期就可以在执行完以后提前结束了。
pub fn parseArgs(allocator: std.mem.Allocator) Runner {
    const cmd = Runner.getCmd();
    const args = cmd.parse(allocator) catch |e|
        zargs.exitf(e, 1, "\n{s}\n", .{cmd.usage()});
    defer cmd.destroy(&args, allocator);
    var runner: @import("cli.zig").Runner = undefined;
    runner = Runner.initFromArgs(args, allocator);
    return runner;
}
