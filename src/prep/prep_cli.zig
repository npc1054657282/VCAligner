const std = @import("std");
const zargs = @import("zargs");
pub const Prep = struct {
    bare_repo_path: []const u8,
    pub fn run(self: Prep) !void {
        std.debug.print("path: {s}", .{self.bare_repo_path});
        return;
    }
    pub fn getCmd() zargs.Command {
        return zargs.Command.new("prep")
            .arg(zargs.Arg.optArg("repo_path", ?[]const u8).long("repo-path"));
    }
    pub fn initFromArgs(args: Prep.getCmd().Result(), allocator: std.mem.Allocator) @import("../cli.zig").Runner {
        const bare_repo_path = allocator.alloc(u8, (args.repo_path orelse "").len) catch |e| {
            std.debug.print("{}", .{e});
            std.process.abort();
        };
        @memcpy(bare_repo_path, args.repo_path orelse "");
        return .{ .prep = .{ .bare_repo_path = bare_repo_path } };
    }
};
