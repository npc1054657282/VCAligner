const std = @import("std");
const zargs = @import("zargs");
pub const Runner = union(enum) {
    prep: @import("prep/prep_cli.zig").Prep,
    pub fn run(self: Runner) !void {
        switch (self) {
            inline else => |case| return case.run(),
        }
    }
    pub fn getCmd() zargs.Command {
        comptime var cmd = zargs.Command.new("gvca").requireSub("sub")
            .about("git version commit aligner")
            .version("0.0.0")
            .author("npc1054657282")
            // TODO: 把全局参数 -v 改为 共享参数！
            .arg(zargs.Arg.opt("verbose", bool).short('v'));
        inline for (@typeInfo(Runner).@"union".fields) |field| {
            cmd = cmd.sub(field.type.getCmd());
        }
        return cmd;
    }
    pub fn initFromArgs(args: Runner.getCmd().Result(), allocator: std.mem.Allocator) Runner {
        // 这里可以插入处理全局参数。但目前我的范式是不使用名义上的全局参数，而是将全局参数变为所有子命令都共同使用一份的“共享参数”
        // 因此这块全局参数的处理逻辑不实现。
        switch (args.sub) {
            inline else => |subarg, subtag| {
                return @FieldType(Runner, @tagName(subtag)).initFromArgs(subarg, allocator);
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
    var runner: @import("cli.zig").Runner = undefined;
    runner = Runner.initFromArgs(args, allocator);
    defer cmd.destroy(&args, allocator);
    return runner;
}
