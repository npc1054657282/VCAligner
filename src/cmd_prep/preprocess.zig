const std = @import("std");
const c_helper = @import("gvca").c_helper;
const c = c_helper.c;
const PrepRunner = @import("PrepRunner.zig");
const diag = @import("gvca").diag;
const Pool = @import("gvca").Pool;
const PathSeq = @import("write.zig").PathSeq;

pub fn preprocess(ctx: *PrepRunner, allocator: std.mem.Allocator, last_diag: *diag.Diagnostic) !void {
    std.debug.print("verbose: {}, path: {s}\n", .{ ctx.global.verbose, ctx.bare_repo_path });
    var git_error_code = c.git_libgit2_init();
    if (git_error_code != 1) try c_helper.gitErrorCodeToZigError(git_error_code, last_diag);
    defer {
        git_error_code = c.git_libgit2_shutdown();
        const tmp_diagnostics_arena = std.heap.ArenaAllocator.init(allocator);
        defer tmp_diagnostics_arena.deinit();
        var tmp_diagnostics: diag.Diagnostics = .{ .arena = tmp_diagnostics_arena };
        c_helper.gitErrorCodeToZigError(git_error_code, &tmp_diagnostics.last_diagnostic) catch |err| tmp_diagnostics.log_all(err);
    }
    ctx.repo = blk: {
        var repo: ?*c.git_repository = undefined;
        git_error_code = c.git_repository_open_bare(&repo, ctx.bare_repo_path.ptr);
        try c_helper.gitErrorCodeToZigError(git_error_code, last_diag);
        break :blk repo.?;
    };
    defer {
        c.git_repository_free(ctx.repo);
        ctx.repo = undefined;
    }
    ctx.odb = blk: {
        var odb: ?*c.git_odb = undefined;
        git_error_code = c.git_repository_odb(&odb, ctx.repo);
        try c_helper.gitErrorCodeToZigError(git_error_code, last_diag);
        break :blk odb.?;
    };
    defer {
        c.git_odb_free(ctx.odb);
        ctx.odb = undefined;
    }
    // oidtype标识仓库的hash是SHA1还是SHA256。
    const oidtype = c.git_repository_oid_type(ctx.repo);
    _ = oidtype;
    ctx.repo_id = try getRepoId(ctx.repo, allocator, last_diag);
    defer {
        allocator.free(ctx.repo_id);
        ctx.repo_id = undefined;
    }
    std.debug.print("repo-id: {s}\n", .{ctx.repo_id});
    ctx.commit_registry = .{ .arena = std.heap.ArenaAllocator.init(allocator) };
    defer {
        ctx.commit_registry.table.deinit(ctx.commit_registry.arena.allocator());
        ctx.commit_registry.arena.deinit();
        ctx.commit_registry = undefined;
    }
    // 初始化两个永远一样的数组。
    ctx.keys_list_sizes = @splat(@sizeOf(PrepRunner.Parsed.KeyBuf));
    ctx.values_list_sizes = @splat(@sizeOf(PrepRunner.CommitSeq));
    // rocksdb的使用方案[参见](https://github.com/facebook/rocksdb/wiki/RocksDB-FAQ)。
    // 采用多线程解析，单线程写入的模型。解析线程同样涉及odb的I/O读取，并不是纯cpu工作，所以恐怕不会比写入的I/O慢。
    const queue = try PrepRunner.Queue.init(allocator, ctx.task_queue_capacity_log2);
    defer queue.deinit(allocator);
    ctx.channel = .{ .mpsc_queue_ref = queue };
    defer ctx.channel = undefined;
    // 创建解析线程池。需要为主线程和写线程各预留1个线程数量。rocksdb的后台flush线程为I/O密集线程，不需要预留。
    try ctx.parsers.init(allocator, ctx.n_jobs - 2, &ctx.channel);
    defer ctx.parsers.deinit(allocator);
    // 创建写线程。
    var writer = try std.Thread.spawn(.{ .allocator = allocator }, @import("write.zig").task, .{ctx});
    defer {
        ctx.parsers.pool.waitAndWork(&ctx.parsers.wait_group);
        ctx.channel.notifyConsumerDone();
        writer.join();
        std.log.info("Writer end.\n", .{});
    }
    git_error_code = c.git_odb_foreach(ctx.odb, index_builder_cb, ctx);
    try c_helper.gitErrorCodeToZigError(git_error_code, last_diag);
}

fn index_builder_cb(id: [*c]const c.git_oid, payload: ?*anyopaque) callconv(.c) c_int {
    var ctx: *PrepRunner = @ptrCast(@alignCast(payload.?));
    const obj_type: c.git_object_t = blk: {
        var obj: ?*c.git_odb_object = undefined;
        const git_error_code = c.git_odb_read(@as([*c]?*c.git_odb_object, &obj), ctx.odb, id);
        if (git_error_code != 0) return git_error_code;
        defer c.git_odb_object_free(obj);
        break :blk c.git_odb_object_type(obj);
    };
    // 只处理commit对象
    if (obj_type != c.GIT_OBJECT_COMMIT) return 0;
    // 注意：遍历过程中，可能出现重复的对象。
    // 参见<https://stackoverflow.com/questions/41050175/why-do-i-see-duplicate-object-ids-when-using-git-odb-foreach>。
    // 这是因为odb仓库可能存在多个后端，遍历odb会把每个后端都遍历一遍，并且不对外开放指定后端的遍历。只遍历指定后端也容易遗漏。
    // 因此，引入本地hash表用于commit去重。如果已存在则不再继续。
    if (ctx.commit_registry.table.contains(id.*)) return 0;
    // 每个commit分配一个序列号，因为每次写入的commit都需要20字节太长了，压缩到4个字节。这个分配过程在此处就执行，并且没有做驻留保存工作。
    const commit_seq = ctx.commit_registry.table.count();
    ctx.commit_registry.table.putNoClobber(ctx.commit_registry.arena.allocator(), id.*, {}) catch {
        std.log.err("Commit regisistry put no clobber failed.\n", .{});
        std.process.abort();
    };
    // 在添加线程池任务前，检查`task_in_queue_count`。若已满，自己也来帮忙执行。此处的最大task数目和另一个mpsc队列共用一个`task_queue_capacity_log2`
    const task_in_queue_count = ctx.parsers.task_in_queue_count.fetchAdd(1, .acquire);
    if ((task_in_queue_count >> ctx.task_queue_capacity_log2) > 0) help_do_work: {
        const run_node = blk: {
            ctx.parsers.pool.mutex.lock();
            defer ctx.parsers.pool.mutex.unlock();
            break :blk ctx.parsers.pool.run_queue.popFirst() orelse break :help_do_work;
        };
        const runnable: *Pool.Runnable = @fieldParentPtr("node", run_node);
        runnable.runFn(runnable, 0);
    }
    // XXX: 一种可能选项是不拷贝id的20字节，而是直接用HashMap里的commi id键指针。
    // 但是，实践中这可能破坏数据局部性，缓存未命中的性能影响远超过此处的拷贝。
    ctx.parsers.pool.spawnWgId(&ctx.parsers.wait_group, @import("parse.zig").task, .{ ctx, id.*, commit_seq });
    return 0;
}

/// 将git url转换为repo-id。repo-id会将git url的协议信息剥去，因为同一仓库往往支持不同协议的git url。
/// git url的解析参考[git-ftech文档](https://git-scm.com/docs/git-fetch)。
/// 返回的repo-id持有内存，需要调用者释放。
// XXX:改用std.Uri的实现？但是这一实现并不支持SCP格式，或许当前这版已经是效率最优的。
pub fn getRepoId(repo: *c.git_repository, allocator: std.mem.Allocator, last_diag: *diag.Diagnostic) ![:0]u8 {
    var origin: *c.git_remote = undefined;
    const git_error_code = c.git_remote_lookup(@ptrCast(&origin), repo, "origin");
    c_helper.gitErrorCodeToZigError(git_error_code, last_diag) catch |err| {
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
    var building_ret: std.ArrayList(u8) = .empty;
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
    url = trim_tail_slash: {
        var end = url.len;
        while ((if (i_slash != null) end - 1 > i_slash.? else true) and url[end - 1] == '/') : (end -= 1) {}
        break :trim_tail_slash url[0..end];
    };
    if (std.mem.endsWith(u8, url, ".git")) {
        url = url[0 .. url.len - ".git".len];
    }
    // 再来一次，消除尾部的斜杠，但不能消除第一个斜杠。
    url = trim_tail_slash: {
        var end = url.len;
        while ((if (i_slash != null) end - 1 > i_slash.? else true) and url[end - 1] == '/') : (end -= 1) {}
        break :trim_tail_slash url[0..end];
    };
    try building_ret.appendSlice(allocator, url);
    return try building_ret.toOwnedSliceSentinel(allocator, 0);
}
