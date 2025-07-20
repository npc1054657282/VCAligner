const std = @import("std");
const c_helper = @import("../c.zig");
const c = c_helper.c;
const PrepRunner = @import("prep_cli.zig").PrepRunner;
const LastError = @import("../error.zig").LastError;

pub fn preprocess(ctx: *PrepRunner, allocator: std.mem.Allocator) !void {
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
    ctx.repo_id = try getRepoId(ctx.repo, allocator, &ctx.last_error);
    defer allocator.free(ctx.repo_id);
    std.debug.print("repo-id: {s}", .{ctx.repo_id});
}

/// 将git url转换为repo-id。repo-id会将git url的协议信息剥去，因为同一仓库往往支持不同协议的git url。
/// git url的解析参考[git-ftech文档](https://git-scm.com/docs/git-fetch)。
/// 返回的repo-id持有内存，需要调用者释放。
pub fn getRepoId(repo: *c.git_repository, allocator: std.mem.Allocator, last_error_out: *LastError) ![:0]u8 {
    var origin: *c.git_remote = undefined;
    const git_error_code = c.git_remote_lookup(@ptrCast(&origin), repo, "origin");
    c_helper.gitErrorCodeToZigError(git_error_code, last_error_out) catch |err| {
        if (err == c_helper.Libgit2Error.GIT_ENOTFOUND) {
            // TODO: 未找到远程origin目录时基于本地仓库路径制作repo_id。当前实现为未找到时出错退出。
        }
        return err;
    };
    defer c.git_remote_free(origin);
    var url: []const u8 = std.mem.span(c.git_remote_url(origin));
    const support_protos = [_][]const u8{
        "file://", "ssh://", "git://", "http://", "https://", "ftp://", "ftps://",
    };
    const i_proto = for (support_protos, 0..) |proto, i| {
        if (std.mem.startsWith(u8, url, proto)) {
            url = url[proto.len..];
            break i;
        }
    } else null;
    // 跳过协议后，无字符是非法的。
    if (url.len == 0) return error.GitRepoInvalidUrl;
    var building_ret: std.ArrayListUnmanaged(u8) = .empty;
    errdefer building_ret.deinit(allocator);
    // 斜杠位置为关键，需动态调整。冒号和@位置仅用于粗处理内部检查。
    var i_slash = std.mem.indexOfScalar(u8, url, '/');
    {
        var i_colon = std.mem.indexOfScalar(u8, url, ':');
        const i_at = std.mem.indexOfScalar(u8, url, '@');
        if (i_proto) |i| {
            if (i != 0) {
                // 对于"file://"以外的有效协议，协议前缀后不存在斜杠是非法的
                if (i_slash == null) return error.GitRepoInvalidUrl;
                if (i_at != null and i_at.? < i_slash.?) {
                    // 跳过在首个斜杠前可能存在的认证信息"user@"前缀，它们与仓库本身无关
                    url = url[i_at.? + 1 ..];
                    i_slash = i_slash.? - (i_at.? + 1);
                }
                // 此时slash在首位（没有host部分）也是非法的
                if (i_slash.? == 0) return error.GitRepoInvalidUrl;
            } else {
                try building_ret.appendSlice(allocator, "file://");
            }
        } else {
            // 对于不属于任何有效协议的情况。
            if (i_colon == null or i_slash != null and i_colon.? > i_slash.?) {
                // 首个斜杠前没有冒号，或既无斜杠也无冒号，判定为本地路径。本地路径反而会添加协议提示。
                try building_ret.appendSlice(allocator, "file://");
            } else {
                // 如果首个斜杠前有冒号，或者有冒号无斜杠，判定为SCP风格。
                // 如果"@"出现在首个冒号前，跳过@之前的内容
                if (i_at != null and i_at.? < i_colon.?) {
                    url = url[i_at.? + 1 ..];
                    i_slash = i_slash.? - (i_at.? + 1);
                    i_colon = i_colon.? - (i_at.? + 1);
                }
                // 首个冒号前没有内容是非法的。
                if (i_colon.? == 0) return error.GitRepoInvalidUrl;
            }
        }
    }
    // 消除尾部的斜杠，但不能消除第一个斜杠。
    url = trim_tail_slash_blk: {
        var end = url.len;
        while ((if (i_slash != null) end - 1 > i_slash.? else true) and url[end - 1] == '/') : (end -= 1) {}
        break :trim_tail_slash_blk url[0..end];
    };
    if (std.mem.endsWith(u8, url, ".git")) {
        url = url[0 .. url.len - ".git".len];
    }
    // 再来一次，消除尾部的斜杠，但不能消除第一个斜杠。
    url = trim_tail_slash_blk: {
        var end = url.len;
        while ((if (i_slash != null) end - 1 > i_slash.? else true) and url[end - 1] == '/') : (end -= 1) {}
        break :trim_tail_slash_blk url[0..end];
    };
    try building_ret.appendSlice(allocator, url);
    return try building_ret.toOwnedSliceSentinel(allocator, 0);
}
