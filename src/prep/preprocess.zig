const std = @import("std");
const c_helper = @import("../c.zig");
const c = c_helper.c;
const PrepRunner = @import("prep_cli.zig").PrepRunner;

pub fn preprocess(ctx: *PrepRunner) !void {
    std.debug.print("verbose: {}, path: {s}", .{ ctx.global.verbose, ctx.bare_repo_path });
    var git_error_code = c.git_libgit2_init();
    if (git_error_code != 1) try c_helper.gitErrorCodeToZigError(git_error_code);
    defer {
        git_error_code = c.git_libgit2_shutdown();
        c_helper.gitErrorCodeToZigError(git_error_code) catch |err| c_helper.logLibgit2Error(err);
    }
    git_error_code = c.git_repository_open_bare(@ptrCast(&ctx.repo), ctx.bare_repo_path.ptr);
    c_helper.gitErrorCodeToZigError(git_error_code) catch |err| {
        c_helper.logLibgit2Error(err);
        return err;
    };
    defer c.git_repository_free(ctx.repo);
    git_error_code = c.git_repository_odb(@ptrCast(&ctx.odb), ctx.repo);
}
