const std = @import("std");
const c_helper = @import("../c.zig");
const c = c_helper.c;
const PrepRunner = @import("prep_cli.zig").PrepRunner;

pub fn preprocess(ctx: *PrepRunner) !void {
    std.debug.print("verbose: {}, path: {s}\n", .{ ctx.global.verbose, ctx.bare_repo_path });
    var git_error_code = c.git_libgit2_init();
    if (git_error_code != 1) try c_helper.gitErrorCodeToZigError(git_error_code, &ctx.last_error);
    defer {
        git_error_code = c.git_libgit2_shutdown();
        c_helper.gitErrorCodeToZigError(git_error_code, &ctx.last_error) catch |err| c_helper.logLibgit2Error(err, ctx.last_error);
    }
    git_error_code = c.git_repository_open_bare(@ptrCast(&ctx.repo), ctx.bare_repo_path.ptr);
    try c_helper.gitErrorCodeToZigError(git_error_code, &ctx.last_error);
    defer c.git_repository_free(ctx.repo);
    git_error_code = c.git_repository_odb(@ptrCast(&ctx.odb), ctx.repo);
    // oidtype标识仓库的hash是SHA1还是SHA256。
    const oidtype = c.git_repository_oid_type(ctx.repo);
    _ = oidtype;
}
