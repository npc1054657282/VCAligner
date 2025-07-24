const std = @import("std");
const c_helper = @import("../c.zig");
const c = c_helper.c;
const PrepRunner = @import("prep_cli.zig").PrepRunner;
const diag = @import("../diagnostics.zig");

pub fn preprocess(ctx: *PrepRunner, allocator: std.mem.Allocator, last_diag: *diag.Diagnostic) !void {
    std.debug.print("verbose: {}, path: {s}\n", .{ ctx.global.verbose, ctx.bare_repo_path });
    var git_error_code = c.git_libgit2_init();
    if (git_error_code != 1) try c_helper.gitErrorCodeToZigError(git_error_code, last_diag);
    defer {
        git_error_code = c.git_libgit2_shutdown();
        const tmp_diagnostics_arena = std.heap.ArenaAllocator.init(allocator);
        var tmp_diagnostics: diag.Diagnostics = .{ .arena = tmp_diagnostics_arena };
        c_helper.gitErrorCodeToZigError(git_error_code, &tmp_diagnostics.last_diagnostic) catch |err| tmp_diagnostics.log_all(err);
        tmp_diagnostics_arena.deinit();
    }
    git_error_code = c.git_repository_open_bare(@ptrCast(&ctx.repo), ctx.bare_repo_path.ptr);
    try c_helper.gitErrorCodeToZigError(git_error_code, last_diag);
    defer c.git_repository_free(ctx.repo);
    git_error_code = c.git_repository_odb(@ptrCast(&ctx.odb), ctx.repo);
    // oidtype标识仓库的hash是SHA1还是SHA256。
    const oidtype = c.git_repository_oid_type(ctx.repo);
    _ = oidtype;
    ctx.repo_id = try getRepoId(ctx.repo, allocator, last_diag);
    defer allocator.free(ctx.repo_id);
    std.debug.print("repo-id: {s}", .{ctx.repo_id});
    // 采用rocksdb方案为：基于SST文件的导入。这种方案要求SST文件完全有序，因此需要额外进行排序工作。
    // 即使如此，这样做的性能依然远远高于直接写入数据库。
    // 在实现过程中，将分为3步走：
    // 1.m个解析线程和2m个I/O写线程，每个解析线程完全并行地各自在本线程内存中为commit、path、blob保存“本地字典”。
    // commit记录时间作为未来排序依据。path记录其对应的blob数作为未来排序依据。blob记录对应的commit数作为未来排序依据。
    // 每个I/O线程产生2个中间文件，该文件基于各自的“字典”将解析到的关系localid_blob_commit和localid_path_blob保存为二进制文件。
    // XXX:不对！解析线程恐怕比I/O写线程要慢，因为解析线程使用了libgit2查找对象，实际上涉及I/O随机读，根本不比一个顺序的写入要快！
    // 实际上生产者和写者的数量倒挂还差不多，一写者或许可以解决好几个生产者的解析结果。但这个写者有可能要写多个文件。
    // 2.各线程把自己的本地字典排序后“充公”，一个独立的线程基于这些字典生成有序的公共字典，顺便为各本地字典提供一个与公共字典的“翻译表”。
    // 这个操作因为是纯内存，不涉及I/O的操作，因此在第1步的解析线程完成以后，在I/O线程仍在继续执行的时候就可以开始做了。
    // 3.再开2m个I/O读线程和n个I/O写线程。读进程读取第1步生成的二进制文件，而每个写线程对应一个FFT文件，但它们此时输出的仍然是一个中间文件。
    // 其中7个比较固定的FFT文件（甲乙丙丁戊己壬）没太多可说的，除了blob字典存在些许分区可能，但仍然不太可能。庚和辛可能需要分区。
    // 一个SST文件的分区大小应该在64MB256MB之间。保守起见，我们将选择64MB的分区。
    // 在第2步的时候，会顺便计算idx_blob_commit和idx_path_blob的sst文件分区边界在哪里，因此此处的I/O读线程可以确定自己要发送给哪个I/O写线程。
    // 4.最后，对新中间文件进行内部排序，这次排序完了以后，终于可以输出为真正的SST文件了。
    // 所有SST都可以随时并行导入。
    /////////////////////////////现在，我正在用libgit2处理一批数据，我的目标是，通过数据库，获取它的文件路径—blob、blob—commit的关系，并且要求对文件路径根据其所包含的blob数目进行排序。目前我使用rocksdb来进行处理。
    // 有以下列族：
    // 甲.commit_to_idx;乙.idx_to_commit;丙.blob_to_idx;丁.idx_to_blob;戊.path_to_idx;己.idx_to_path;庚.idx_blob_commit;辛:idx_path_blob;壬:default
    // rocksdb的使用方案[参见](https://github.com/facebook/rocksdb/wiki/RocksDB-FAQ)。
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
