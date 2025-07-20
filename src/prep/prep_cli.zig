const std = @import("std");
const zargs = @import("zargs");
const Runner = @import("../cli.zig").Runner;
const c = @import("../c.zig").c;
const LastError = @import("../error.zig").LastError;
pub const PrepRunner = struct {
    global: Runner.Global,
    bare_repo_path: [:0]u8,
    last_error: LastError = undefined,
    repo: *c.git_repository = undefined,
    odb: *c.git_odb = undefined,
    repo_id: [:0]u8 = undefined,
    pub const cmd = Runner.Global.sharedArgs(zargs.Command.new("prep"))
        .arg(zargs.Arg.optArg("repo_path", ?[]const u8).long("repo-path"))
        .arg(zargs.Arg.optArg("bare_repo_path", ?[]const u8).long("bare-repo-path"));
    pub fn run(self: *PrepRunner, allocator: std.mem.Allocator) !void {
        try @import("preprocess.zig").preprocess(self, allocator);
        return;
    }
    pub fn initFromArgs(args: PrepRunner.cmd.Result(), allocator: std.mem.Allocator) !Runner {
        var building_bare_repo_path: std.ArrayListUnmanaged(u8) = .empty;
        errdefer building_bare_repo_path.deinit(allocator);
        if (args.bare_repo_path) |bare_repo_path| {
            try building_bare_repo_path.appendSlice(allocator, bare_repo_path);
        } else if (args.repo_path) |repo_path| {
            try building_bare_repo_path.appendSlice(allocator, repo_path);
            try building_bare_repo_path.appendSlice(allocator, "/.git");
        } else {
            std.log.err("Option `bare-repo-path` or `repo-path` is necessary.", .{});
            return Runner.Error.CliArgInvalidInput;
        }
        return .{ .prep = .{ .global = Runner.Global.initGlobal(args), .bare_repo_path = try building_bare_repo_path.toOwnedSliceSentinel(allocator, 0) } };
    }
    pub fn deinit(self: *PrepRunner, allocator: std.mem.Allocator) void {
        allocator.free(self.bare_repo_path);
        self.bare_repo_path = undefined;
    }
};
