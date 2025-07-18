const std = @import("std");
const zargs = @import("zargs");
const cli = @import("../cli.zig");
const c = @import("../c.zig").c;
pub const PrepRunner = struct {
    global: cli.Runner.Global,
    bare_repo_path: [:0]u8,
    repo: *c.git_repository = undefined,
    odb: *c.git_odb = undefined,
    pub const cmd = cli.Runner.Global.sharedArgs(zargs.Command.new("prep"))
        .arg(zargs.Arg.optArg("repo_path", ?[]const u8).long("repo-path"))
        .arg(zargs.Arg.optArg("bare_repo_path", ?[]const u8).long("bare-repo-path"));
    pub fn run(self: *PrepRunner) !void {
        try @import("preprocess.zig").preprocess(self);
        return;
    }
    pub fn initFromArgs(args: PrepRunner.cmd.Result(), allocator: std.mem.Allocator) !cli.Runner {
        var building_bare_repo_path: std.ArrayListUnmanaged(u8) = .empty;
        errdefer building_bare_repo_path.deinit(allocator);
        if (args.bare_repo_path) |bare_repo_path| {
            try building_bare_repo_path.appendSlice(allocator, bare_repo_path);
        } else if (args.repo_path) |repo_path| {
            try building_bare_repo_path.appendSlice(allocator, repo_path);
            try building_bare_repo_path.appendSlice(allocator, "/.git");
        } else {
            std.log.err("Option `bare-repo-path` or `repo-path` is necessary.", .{});
            return cli.Runner.Error.CliArgInvalidInput;
        }
        return .{ .prep = .{ .global = cli.Runner.Global.initGlobal(args), .bare_repo_path = try building_bare_repo_path.toOwnedSliceSentinel(allocator, 0) } };
    }
    pub fn deinit(self: *PrepRunner, allocator: std.mem.Allocator) void {
        allocator.free(self.bare_repo_path);
        self.bare_repo_path = undefined;
    }
};
