const std = @import("std");
const zargs = @import("zargs");
const cli = @import("../cli.zig");
pub const Prep = struct {
    global: cli.Runner.Global,
    bare_repo_path: []const u8,
    pub const cmd = cli.Runner.sharedArgs(zargs.Command.new("prep"))
        .arg(zargs.Arg.optArg("repo_path", ?[]const u8).long("repo-path"));
    pub fn run(self: *Prep) !void {
        std.debug.print("verbose: {}, path: {s}", .{ self.global.verbose, self.bare_repo_path });
        return;
    }
    pub fn initFromArgs(args: Prep.cmd.Result(), allocator: std.mem.Allocator) cli.Runner {
        const bare_repo_path = allocator.alloc(u8, (args.repo_path orelse "").len) catch |e| {
            std.debug.print("{}", .{e});
            std.process.abort();
        };
        @memcpy(bare_repo_path, args.repo_path orelse "");
        return .{ .prep = .{ .global = cli.Runner.initGlobal(args), .bare_repo_path = bare_repo_path } };
    }
};
