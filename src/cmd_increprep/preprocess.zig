const std = @import("std");
const PrepRunner = @import("PrepRunner.zig");
const vcaligner = @import("vcaligner");
const c_helper = vcaligner.c_helper;
const c = c_helper.c;
const diag = vcaligner.diag;
const StArena = vcaligner.StArena;
const PathSeq = vcaligner.rocksdb_custom.PathSeq;
const CommitSeq = vcaligner.rocksdb_custom.CommitSeq;
const BlobPathKey = vcaligner.rocksdb_custom.BlobPathKey;
const BlobPathSeq = vcaligner.rocksdb_custom.BlobPathSeq;

// XXX: 当前，一个`Parsed`允许包含一个commit及其对应的多个blob-path。
// 注意，这并不代表它包含一个commit及其对应的所有blob-path。
// 因为一个commit如果对应的blob-path过多，它可能被切割为多个`Parsed`。
// 未来可能考虑如果一个commit包含的blob-path过少，则一个`Parsed`可以承载多个commit。这可能要求此结构变得复杂一些。
// 目前的考虑是实践中大体量的仓库一般各个commit包含的blob-path都很多。而小体量的仓库不需要为此特别考虑优化。
pub const Parsed = struct {
    // XXX: 考虑到分配器采用c allocator，glibc的分配器不会跨线程共享缓存
    // 因此当前采用“生产线程分配arena，消费线程销毁arena”的设计可能会因此性能不佳。
    // 未来可能每个线程会有自己的可复用回收的arena池，此处的arena可能会改为线程id + arena池索引。
    arena: StArena,
    commit_seq: CommitSeq,
    parsed_units: std.ArrayList(ParsedUnit),
    pub const ParsedUnit = struct {
        blob_hash: c.git_oid,
        // `path`的所有权属于`Parsed`内的`arena`。
        path: []u8,
    };
};
pub const Queue = @import("mpsc_queue").AnyMpscQueue(Parsed, null);
pub const Channel = vcaligner.MpscChannel(Queue);

pub const PathRegistry = struct {
    map: std.StringArrayHashMapUnmanaged(struct {
        // 初次插入时的index。插入同时记录，因为后续排序时，原始index会丢失
        index: PathSeq,
        blob_cnt: usize,
    }),
    // arena很重要，注意`StringArrayHashMapUnmanaged`不会拷贝键，因此键需要自己手动拷贝保存
    // 因此arena不仅负责`StringArrayHashMapUnmanaged`，还负责键的保存。
    arena: StArena,
    pub fn deinit(self: *PathRegistry) void {
        self.map.deinit(self.arena.allocator());
        self.arena.deinit();
        self.* = undefined;
    }
};
pub const BlobPathRegistry = struct {
    map: std.AutoHashMapUnmanaged(BlobPathKey, BlobPathSeq),
    arena: StArena,
    pub fn deinit(self: *BlobPathRegistry) void {
        self.map.deinit(self.arena.allocator());
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const CommitRegistry = struct {
    // XXX: HashMap不记录插入顺序，而ArrayHashMap只要不删除内部元素就能确保记录插入顺序。ArrayHashMap有高得多的迭代效率。
    // 目前需求：查找频繁，最后迭代一次。迭代是无序的。
    // 目前基于最高查询效率的目的采用HashMap。未来或考虑array hash map。
    map: std.AutoHashMapUnmanaged(c.git_oid, CommitSeq),
    arena: StArena,
    pub fn deinit(self: *CommitRegistry) void {
        self.map.deinit(self.arena.allocator());
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const RocksdbPath = union(enum) {
    borrowed_from_config: [:0]const u8,
    owned: [:0]u8,
    pub fn init(
        noalias runconf: *const PrepRunner,
        repo: *c.git_repository,
        allocator: std.mem.Allocator,
        last_diag: *diag.Diagnostic,
    ) !RocksdbPath {
        return switch (runconf.mode_conf) {
            .full => |full_conf| switch (full_conf.rocksdb_output) {
                .manual => |path| .{ .borrowed_from_config = path },
                .auto => blk: {
                    // repo_id曾考虑参与更多，如在rocksdb中被保存
                    // 由于repo_id目前实现不完善（仅仅只有repo中包含远程origin才能提取）且目前仅在自动创建rocksdb_outpu时才有用
                    // 因此它的创建目前仅仅在自动创建rocksdb_output时才会进行。
                    const repo_id = try getRepoId(repo, allocator, last_diag);
                    defer allocator.free(repo_id);
                    var rocksdb_output_auto_writer: std.Io.Writer.Allocating = .init(allocator);
                    errdefer rocksdb_output_auto_writer.deinit();
                    try rocksdb_output_auto_writer.writer.print("tmp/{s}/{d}-{d}-rocksdb", .{
                        repo_id,
                        runconf.proc_stamp.pid,
                        runconf.proc_stamp.ts,
                    });
                    break :blk .{ .owned = try rocksdb_output_auto_writer.toOwnedSliceSentinel(0) };
                },
            },
            .incremental => |inc_conf| .{ .borrowed_from_config = inc_conf.rocksdb_output },
        };
    }
    pub fn deinit(self: RocksdbPath, allocator: std.mem.Allocator) void {
        switch (self) {
            .borrowed_from_config => {},
            .owned => |path| allocator.free(path),
        }
    }
    pub fn get(self: RocksdbPath) [:0]const u8 {
        return switch (self) {
            .borrowed_from_config, .owned => |path| path,
        };
    }
};

pub fn preprocess(noalias runconf: *const PrepRunner, allocator: std.mem.Allocator, last_diag: *diag.Diagnostic) !void {
    // 此重构版本，主线程为写入线程，解析主线程另开线程。
    var path_registry: PathRegistry = .{ .map = .empty, .arena = .init(allocator) };
    defer path_registry.deinit();
    var blob_path_registry: BlobPathRegistry = .{ .map = .empty, .arena = .init(allocator) };
    defer blob_path_registry.deinit();
    var commit_registry: CommitRegistry = .{ .map = .empty, .arena = .init(allocator) };
    // NOTE：commit_registry的生存期：如果是立即写入子列族，一般在解析线程那里就可以释放了。如果是仅延迟写入子列族，那么写入线程的延迟写入阶段结束可以释放。
    // TODO: 目前的解构时机是出于简单考虑，未来考虑精细设计。
    defer commit_registry.deinit();
    const queue: Queue = try .init(allocator, runconf.parsed_queue_capacity_log2);
    // TODO: 目前的解构时机是出于简单考虑，未来考虑精细设计。
    defer queue.deinit(allocator);
    // TODO: channel的生存期未来考虑精细设计。
    var channel: Channel = .{ .mpsc_queue_ref = queue };
    // 将libgit2初始化本身作为一种资源。本块会初始化这个资源，最终将它的所有权移交给main parser线程来shutdown。
    // 在main parser线程创建前，依赖于libgit2获取的其他资源一并由这个块返回。
    var main_parser_allocator_instance: vcaligner.GpaInstance = .init();
    defer main_parser_allocator_instance.deinit();
    const main_parser: std.Thread, const rocksdb_output: RocksdbPath = libgit2_handoff: {
        var git_error_code = c.git_libgit2_init();
        if (git_error_code < 0) try c_helper.gitErrorCodeToZigError(git_error_code, last_diag);
        std.debug.assert(git_error_code == 1);
        // 下面的写法模拟对libgit2资源本身的`errdefer`。由于libgit2的销毁本身可能报错，且`errdefer`本身将移除捕获`err`的能力。
        // 因此，当前的`errdefer`对于这种本身可能报错的逻辑无法收集所有信息得到最优控制流。
        // 因此还是选择将主要逻辑放进函数里，模拟`errdefer`的行为。
        break :libgit2_handoff provisionMainParser(
            runconf,
            main_parser_allocator_instance.allocator(),
            &commit_registry,
            &channel,
            allocator,
            last_diag,
        ) catch |err| {
            git_error_code = c.git_libgit2_shutdown();
            if (git_error_code < 0) {
                try last_diag.enterStack(err);
                try c_helper.gitErrorCodeToZigError(git_error_code, last_diag);
                unreachable;
            }
            std.debug.assert(git_error_code == 0);
            return err;
        };
    };
    defer rocksdb_output.deinit(allocator);
    // 即使后续的mpsc协调中，能保障此线程的生产者生产完毕本函数才退出，
    // 此处的join依然有保障本函数结束前此线程持有的libgit2全局资源以及repo被释放的能力。
    // XXX: 如果不把libgit2全局资源和repo的所有权传递给解析线程，而是选择在此处`join`之后由本线程释放呢？
    // 这么写代码逻辑会更简单一些，不过所有权提交给解析线程有机会可以更早释放。
    defer main_parser.join();
    // 全量模式创建rocksdb_output的父目录。这是因为rocksdb没有自动创建父目录的能力。
    if (runconf.mode_conf == .full) make_parent_dir: {
        // NOTE：父目录解析为`null`存在一个合法可能：`rocksdb_output`只有名字。此时父目录解析为`null`意味着父目录为当前目录。
        // 其它情况下解析为`null`的情况，不论是`rocksdb_output`是当前目录，或者是一个盘符都是非法的。
        // 这种情况将在`rocksdb`创建数据库的时候报告错误，因此此处不再检查。
        const maybe_parent_dir: ?[]const u8 = std.fs.path.dirname(rocksdb_output.get());
        if (maybe_parent_dir) |parent_dir| {
            const cwd = std.fs.cwd();
            cwd.access(parent_dir, .{}) catch |access_err| {
                switch (access_err) {
                    error.FileNotFound => cwd.makePath(parent_dir) catch |mkdir_err| {
                        switch (mkdir_err) {
                            // 考虑多进程竞争场景，可能存在同进程已经创建目录的情形。此时是安全的。
                            error.PathAlreadyExists => {},
                            else => {
                                std.log.err("make dir {s} error: {s}", .{ parent_dir, @errorName(mkdir_err) });
                                return mkdir_err;
                            },
                        }
                    },
                    else => return access_err,
                }
            };
        }
        break :make_parent_dir;
    }
}

fn provisionMainParser(
    noalias runconf: *const PrepRunner,
    main_parser_allocator: std.mem.Allocator,
    commit_registry: *CommitRegistry,
    channel: *Channel,
    allocator: std.mem.Allocator,
    last_diag: *diag.Diagnostic,
) !struct { std.Thread, RocksdbPath } {
    const compaction_strategy: PrepRunner.CompactionStrategy = runconf.mode_conf.compactionStrategy();
    _ = compaction_strategy;
    const repo: *c.git_repository = blk: {
        var repo: ?*c.git_repository = undefined;
        const git_error_code = c.git_repository_open_bare(&repo, runconf.bare_repo_path.ptr);
        try c_helper.gitErrorCodeToZigError(git_error_code, last_diag);
        break :blk repo.?;
    };
    errdefer c.git_repository_free(repo);
    // oidtype标识仓库的hash是SHA1还是SHA256。
    // TODO: 将它输出，与repo id一起写进数据库里。
    const oidtype = c.git_repository_oid_type(repo);
    _ = oidtype;
    const rocksdb_output: RocksdbPath = try .init(runconf, repo, allocator, last_diag);
    errdefer rocksdb_output.deinit(allocator);
    const main_parser = try std.Thread.spawn(.{ .allocator = allocator }, @import("parse.zig").mainParseTaskTakeRepo, .{
        repo,
        channel,
        // n_jobs是排除rocksdb自动创建线程外的线程数。而解析子线程的数量还需要再排除主解析和写线程各一个。
        runconf.n_jobs - 2,
        commit_registry,
        main_parser_allocator,
    });
    errdefer comptime unreachable;
    return .{ main_parser, rocksdb_output };
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
