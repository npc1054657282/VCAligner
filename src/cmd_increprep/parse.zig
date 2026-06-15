const std = @import("std");
const PrepRunner = @import("PrepRunner.zig");
const vcaligner = @import("vcaligner");
const diag = vcaligner.diag;
const StArena = vcaligner.StArena;
const c_helper = vcaligner.c_helper;
const c = c_helper.c;
const CommitRegistry = @import("preprocess.zig").CommitRegistry;

const CommitSeq = vcaligner.rocksdb_custom.CommitSeq;

pub const Queue = @import("mpsc_queue").AnyMpscQueue(Parsed, null);
pub const Channel = vcaligner.MpscChannel(Queue);
pub const Parsed = struct {
    arena: StArena,
    commit_seq: CommitSeq,
    // XXX: 考虑`MultiArrayList`，但是实际使用有些困难，因为实际上我的需求是要为key与path本身设计列表，也要为key的指针设计列表。
    // 如果`MultiArrayList`的各个成员之间有地址依赖，该怎么设计，我感到头疼。因此目前依然是设计为分开的`ArrayList`
    // 可能并非必要，因为已经在arena中分配？
    // path_strings: std.ArrayList(u8),
    parsed_units: std.ArrayList(ParsedUnit),
    pub const ParsedUnit = struct {
        path: []u8,
        blob_hash: c.git_oid,
    };
};

const ParserBlocks = struct {
    heap_ptr: *align(heap_align.toByteUnits()) Header,
    main_parser_allocator: std.mem.Allocator,
    main_parser_last_diag: *diag.Diagnostic,
    n_subparserjobs: usize,
    pub const Header = struct {
        task_in_queue_count: struct {
            _: void align(std.atomic.cache_line),
            v: std.atomic.Value(usize),
        },
        main_parser_block: struct {
            _: void align(std.atomic.cache_line),
            station: ParserStation,
        },
        pub inline fn subParserBlocksPtr(heap_ptr: *Header) [*]SubParser {
            return @ptrCast(@alignCast(@as([*]u8, @ptrCast(heap_ptr)) + sub_parser_blocks_offset));
        }
    };
    pub const sub_parser_blocks_offset = std.mem.alignForward(usize, @sizeOf(Header), @alignOf(SubParser));
    pub fn heapSize(n_subparserjobs: usize) usize {
        return sub_parser_blocks_offset + (@sizeOf(SubParser) * n_subparserjobs);
    }
    pub const heap_align: std.mem.Alignment = .max(.of(Header), .of(SubParser));
    pub const SubParser = struct {
        _: void align(std.atomic.cache_line),
        allocator_impl: vcaligner.Gpa,
        diagnostics: diag.Diagnostics,
        station: ParserStation,
    };
    pub fn init(n_subparserjobs: usize, channel: *Channel, allocator: std.mem.Allocator, last_diag: *diag.Diagnostic) !ParserBlocks {
        const raw = try allocator.alignedAlloc(u8, heap_align, heapSize(n_subparserjobs));
        errdefer allocator.free(raw);
        const heap_ptr: *align(heap_align.toByteUnits()) Header = @ptrCast(raw);
        heap_ptr.task_in_queue_count = .{ ._ = {}, .v = .init(0) };
        heap_ptr.main_parser_block = .{ ._ = {}, .station = .init(channel, allocator) };
        errdefer heap_ptr.main_parser_block.station.deinit();
        try vcaligner.crash_dump.reg("parser", 0, &heap_ptr.main_parser_block.station.dumpable);
        errdefer vcaligner.crash_dump.unreg("parser", 0);
        const sub_parser_blocks: []SubParser = heap_ptr.subParserBlocksPtr()[0..n_subparserjobs];
        const sub_parser_blocks_init_result: union(enum) { success: void, failed: struct {
            err: std.mem.Allocator.Error,
            slice_id: usize,
        } } = blk: for (sub_parser_blocks, 0..) |*sub_parser_block, slice_id| {
            sub_parser_block.allocator_impl = .init();
            errdefer sub_parser_block.allocator_impl.deinit();
            const sub_parser_allocator = sub_parser_block.allocator_impl.getAllocator();
            sub_parser_block.diagnostics = .{ .arena = .init(sub_parser_allocator) };
            errdefer sub_parser_block.diagnostics.arena.deinit();
            sub_parser_block.station = .init(channel, sub_parser_allocator);
            errdefer sub_parser_block.station.deinit();
            vcaligner.crash_dump.reg("parser", slice_id + 1, &sub_parser_block.station.dumpable) catch |err| break :blk .{
                .failed = .{
                    .err = err,
                    .slice_id = slice_id,
                },
            };
        } else .success;
        return switch (sub_parser_blocks_init_result) {
            .failed => |failed| ret: {
                for (0..failed.slice_id) |slice_id| {
                    vcaligner.crash_dump.unreg("parser", slice_id + 1);
                    const sub_parser_block = &sub_parser_blocks[slice_id];
                    sub_parser_block.station.deinit();
                    sub_parser_block.diagnostics.arena.deinit();
                    sub_parser_block.allocator_impl.deinit();
                }
                break :ret failed.err;
            },
            .success => .{
                .heap_ptr = heap_ptr,
                .main_parser_allocator = allocator,
                .main_parser_last_diag = last_diag,
                .n_subparserjobs = n_subparserjobs,
            },
        };
    }
    pub fn deinit(self: ParserBlocks, allocator: std.mem.Allocator) void {
        vcaligner.crash_dump.unreg("parser", 0);
        self.heap_ptr.main_parser_block.station.deinit();
        const sub_parser_blocks: []SubParser = self.heap_ptr.subParserBlocksPtr()[0..self.n_subparserjobs];
        for (sub_parser_blocks, 1..) |*sub_parser_block, thread_id| {
            vcaligner.crash_dump.unreg("parser", thread_id);
            sub_parser_block.station.deinit();
            sub_parser_block.diagnostics.arena.deinit();
            sub_parser_block.allocator_impl.deinit();
        }
        const raw = @as([*]align(heap_align.toByteUnits()) u8, @ptrCast(self.heap_ptr))[0..heapSize(self.n_subparserjobs)];
        allocator.free(raw);
    }
    pub fn lctxFromThreadId(self: ParserBlocks, thread_id: usize) struct {
        std.mem.Allocator,
        *diag.Diagnostic,
        *ParserStation,
    } {
        if (thread_id == 0) return .{
            self.main_parser_allocator,
            self.main_parser_last_diag,
            &self.heap_ptr.main_parser_block.station,
        };
        const sub_parser_block: *SubParser = &self.heap_ptr.subParserBlocksPtr()[0..heapSize(self.n_subparserjobs)][thread_id - 1];
        return .{
            sub_parser_block.allocator_impl.getAllocator(),
            &sub_parser_block.diagnostics.last_diagnostic,
            &sub_parser_block.station,
        };
    }
};

// 各个解析线程的本地上下文。
const ParserStation = struct {
    producer_local: Queue.ProducerLocal,
    // 以下内容为当前任务的缓存，下一个任务起重置。
    // TODO: 亟待重构
    current_task: struct {
        arena: StArena,
        commit_seq: CommitSeq,
    },
    // 以下内容为当前批次内容，flush过了就重置。
    to_flush: Parsed,
    // 当全局崩溃时，打印相关信息。目前打印arena分配的空间大小。
    dumpable: vcaligner.CrashDump.Dumpable,

    pub fn init(channel: *Channel, allocator: std.mem.Allocator) ParserStation {
        return .{
            .producer_local = channel.mpsc_queue_ref.initProducerLocal(),
            .current_task = .{
                .arena = .init(allocator),
                //TODO: 缺省未定义的`commit_seq`在`dumpFn`打印时不安全。当dump机制被彻底弃用后，消除此TODO。
                .commit_seq = undefined,
            },
            .to_flush = undefined,
            .dumpable = .{ .dumpFn = dumpFn },
        };
    }
    pub fn deinit(self: *ParserStation) void {
        self.current_task.arena.deinit();
        self.* = undefined;
    }
    fn dumpFn(dumpable: *vcaligner.CrashDump.Dumpable) void {
        const parsing: *ParserStation = @alignCast(@fieldParentPtr("dumpable", dumpable));
        // TODO：弃用CrashDump！崩溃时打印，会由崩溃线程打印其它线程的信息。此处的信息获取存在数据竞争。CrashDump应当被完全废弃。
        std.log.info("task capacity: {d}\n", .{parsing.current_task.arena.queryCapacity()});
        std.log.info("commit_seq: {d}\n", .{parsing.current_task.commit_seq.toNative()});
    }
};

// zig线程的`spawn`允许线程的任务函数有错误返回值。但是，它的实际效果并不美好：出现的错误会报告日志，但是不会对主线程产生丝毫影响，主线程无法感知到出错。
// 因此，相比主线程无法得知解析线程出错，还不如出错就崩溃。
pub fn mainParseTaskTakeRepo(
    repo: *c.git_repository,
    task_queue_capacity_log2: u5,
    n_subparserjobs: usize,
    commit_registry: *CommitRegistry,
    allocator: std.mem.Allocator,
) void {
    // XXX: 此处的`main_parse_diagnostics`会进行某种复用，详见`Parsers`。另一种更简单的设计是分别使用两个diagnostics对象，但我停不下来了。
    // TODO: 经过仔细思考：当前的诊断模式是反模式，正确的模式是依赖注入的错误处理上下文。
    // 通过定制的错误处理上下文逻辑，辅以合理的错误处理传参规范，可以实现当前诊断模式的一切行为，且具体行为由错误处理上下文而非子模块自己去做。
    // 将来应当直接替换，且错误处理上下文极有可能由调用者传入。
    var main_parse_diagnostics: diag.Diagnostics = .{ .arena = .init(allocator) };
    defer main_parse_diagnostics.arena.deinit();
    const last_diag = &main_parse_diagnostics.last_diagnostic;
    (main_parse_ret: {
        // 注意repo的生命周期必须短于libgit2全局资源，但是目前假定libgit2全局资源的报错将无法使用`defer`，因此封装进单独块。
        (main_parse_except_shutdown_libgit2: {
            defer c.git_repository_free(repo);
            break :main_parse_except_shutdown_libgit2 mainParse(
                repo,
                task_queue_capacity_log2,
                n_subparserjobs,
                commit_registry,
                allocator,
                last_diag,
            );
        }) catch |err| {
            // 出于不适用`defer`，故在错误点和结尾重复一次清理libgit2全局资源逻辑。
            // XXX: 考虑改写`gitErrorCodeToZigError`，允许传入一个`?anyerror`参数。但考虑到诊断模式本身将来大概会被弃用，因此不再做这些复杂考量。
            const git_error_code = c.git_libgit2_shutdown();
            if (git_error_code < 0) {
                last_diag.enterStack(err) catch |e| break :main_parse_ret e;
                c_helper.gitErrorCodeToZigError(git_error_code, last_diag) catch |e| break :main_parse_ret e;
                unreachable;
            }
            std.debug.assert(git_error_code == 0);
        };
        // libgit2的全局资源在逻辑上也被移交给了main parse线程管理。
        // 但是全局资源销毁可能报错，因此相关逻辑无法使用`defer`，只能在结尾模拟。
        const git_error_code = c.git_libgit2_shutdown();
        c_helper.gitErrorCodeToZigError(git_error_code, last_diag) catch |e| break :main_parse_ret e;
        std.debug.assert(git_error_code == 0);
        break :main_parse_ret {};
    }) catch |err| {
        main_parse_diagnostics.log_all(err);
        main_parse_diagnostics.clear();
        // TODO: 未来升级到`std.Io`，有了取消机制后，考虑将各线程错误以某种机制传递给监控线程，而监控线程发现有错误发生时取消所有任务。
        // 但是当前实现此机制开销很大，且未来终究会升级版本。因此我选择线程边界的错误直接崩溃。
        vcaligner.crash_dump.dumpAndCrash(@src());
    };
}

pub fn mainParse(
    repo: *c.git_repository,
    task_queue_capacity_log2: u5,
    n_subparserjobs: usize,
    commit_registry: *CommitRegistry,
    allocator: std.mem.Allocator,
    last_diag: *diag.Diagnostic,
) !void {
    const odb: *c.git_odb = blk: {
        var odb: ?*c.git_odb = undefined;
        const git_error_code = c.git_repository_odb(&odb, repo);
        try c_helper.gitErrorCodeToZigError(git_error_code, last_diag);
        break :blk odb.?;
    };
    defer c.git_odb_free(odb);
    const queue: Queue = try .init(allocator, task_queue_capacity_log2);
    defer queue.deinit(allocator);
    var channel: Channel = .{ .mpsc_queue_ref = queue };
    var ctx: IndexBuilderCbPayload = .{
        .odb = odb,
        .commit_registry = commit_registry,
        .task_queue_capacity_log2 = task_queue_capacity_log2,
        .parsers_lctxs_storage = undefined,
        .pool = undefined,
        .wait_group = .{},
    };
    ctx.parsers_lctxs_storage = try .init(n_subparserjobs, &channel, allocator, last_diag);
    defer ctx.parsers_lctxs_storage.deinit(allocator);
    try ctx.pool.init(.{ .allocator = allocator, .n_jobs = n_subparserjobs, .track_ids = true });
    defer ctx.pool.deinit();
    defer {
        // TODO: 在报错的情况下，真的还需要把堆积的任务做完吗？预测如果升级到0.16，`defer`内的逻辑需要修改为取消，而此处的逻辑不再放在`defer`内。
        ctx.pool.waitAndWork(&ctx.wait_group);
        channel.notifyConsumerDone();
    }
    const git_error_code = c.git_odb_foreach(odb, index_builder_cb, &ctx);
    try c_helper.gitErrorCodeToZigError(git_error_code, last_diag);
}

const IndexBuilderCbPayload = struct {
    odb: *c.git_odb,
    commit_registry: *CommitRegistry,
    task_queue_capacity_log2: u5,
    parsers_lctxs_storage: ParserBlocks,
    pool: vcaligner.Pool,
    wait_group: std.Thread.WaitGroup,
};
fn index_builder_cb(id: [*c]const c.git_oid, payload: ?*anyopaque) callconv(.c) c_int {
    var ctx: *IndexBuilderCbPayload = @ptrCast(@alignCast(payload.?));
    const obj_type: c.git_object_t = blk: {
        var obj: ?*c.git_odb_object = undefined;
        const git_error_code = c.git_odb_read(@as([*c]?*c.git_odb_object, &obj), ctx.odb, id);
        if (git_error_code != 0) return git_error_code;
        defer c.git_odb_object_free(obj);
        break :blk c.git_odb_object_type(obj);
    };
    // 只处理commit对象
    if (obj_type != c.GIT_OBJECT_COMMIT) return 0;
    // NOTE: 遍历过程中，可能出现重复的对象。
    // 参见<https://stackoverflow.com/questions/41050175/why-do-i-see-duplicate-object-ids-when-using-git-odb-foreach>。
    // 这是因为odb仓库可能存在多个后端，遍历odb会把每个后端都遍历一遍，并且不对外开放指定后端的遍历。只遍历指定后端也容易遗漏。
    // 因此，引入本地hash表用于commit去重。如果已存在则不再继续。
    // 引入增量模式后，已经分析过的commit在开头就被分析过一次了，因此此处的基于hash表的逻辑再次用于在增量模式中跳过已有commit。
    // XXX: 考虑允许配置为另一种并非直接遍历所有commit，而是基于对每个后端按树型遍历的模式。可能在增量中更有优势，但不确定。
    if (ctx.commit_registry.map.contains(id.*)) return 0;
    // 每个commit分配一个序列号，因为每次写入的commit都需要20字节太长了，压缩到4个字节。这个分配过程在此处就执行，并且没有做驻留保存工作。
    const commit_seq: vcaligner.rocksdb_custom.CommitSeq = .fromNative(ctx.commit_registry.map.count());
    ctx.commit_registry.map.putNoClobber(ctx.commit_registry.arena.allocator(), id.*, commit_seq) catch {
        std.log.err("Commit regisistry put no clobber failed.\n", .{});
        vcaligner.crash_dump.dumpAndCrash(@src());
    };
    // 在添加线程池任务前，检查`task_in_queue_count`。若已满，自己也来帮忙执行。此处的最大task数目和另一个mpsc队列共用一个`task_queue_capacity_log2`
    const task_in_queue_count = ctx.parsers_lctxs_storage.heap_ptr.task_in_queue_count.v.fetchAdd(1, .acquire);
    if ((task_in_queue_count >> ctx.task_queue_capacity_log2) > 0) help_do_work: {
        const run_node = blk: {
            ctx.pool.mutex.lock();
            defer ctx.pool.mutex.unlock();
            break :blk ctx.pool.run_queue.popFirst() orelse break :help_do_work;
        };
        const runnable: *vcaligner.Pool.Runnable = @fieldParentPtr("node", run_node);
        runnable.runFn(runnable, 0);
    }
    // XXX: 一种可能选项是不拷贝id的20字节，而是直接用HashMap里的commi id键指针。
    // 但是，实践中这可能破坏数据局部性，缓存未命中的性能影响远超过此处的拷贝。
    ctx.pool.spawnWgId(&ctx.wait_group, subParseTask, .{ ctx.parsers_lctxs_storage, id.*, commit_seq });
    return 0;
}

pub fn subParseTask(
    thrd_id: usize,
    parsers_lctxs_storage: ParserBlocks,
    commit_hash: c.git_oid,
    commit_seq: vcaligner.rocksdb_custom.CommitSeq,
) void {
    const allocator, const last_diag, const lctx = parsers_lctxs_storage.lctxFromThreadId(thrd_id);
    // 进入解析，降低积压的`task_in_queue_count`
    _ = parsers_lctxs_storage.heap_ptr.task_in_queue_count.v.fetchSub(1, .release);
    _ = allocator;
    _ = last_diag;
    _ = lctx;
    _ = commit_hash;
    _ = commit_seq;
}
