const std = @import("std");
const PrepRunner = @import("PrepRunner.zig");
const vcaligner = @import("vcaligner");
const diag = vcaligner.diag;
const StArena = vcaligner.StArena;
const c_helper = vcaligner.c_helper;
const c = c_helper.c;
const CommitRegistry = @import("preprocess.zig").CommitRegistry;
const Parsed = @import("preprocess.zig").Parsed;
const CommitMeta = @import("preprocess.zig").CommitMeta;
const MsgToWriter = @import("preprocess.zig").MsgToWriter;
const Queue = @import("preprocess.zig").Queue;
const Channel = @import("preprocess.zig").Channel;

const CommitSeq = vcaligner.rocksdb_custom.CommitSeq;

// XXX: 原计划将`repo`也作为上下文放入此处。但是考虑到未来未来的扩容性：
// 将来可能将程序设计为服务器式的，所有解析线程并非只分析一个repo而可能分析数个repo。因此依然将repo以参数形式传入而非放入此上下文中。
const ParsersHub = struct {
    heap_ptr: *align(heap_align.toByteUnits()) Header,
    main_parser_gpa: vcaligner.gpa.Concurrent,
    main_parser_last_diag: *diag.Diagnostic,
    n_subparserjobs: usize,
    pub const Header = struct {
        task_in_queue_count: struct {
            _: void align(std.atomic.cache_line),
            v: std.atomic.Value(usize),
        },
        main_parser_block: struct {
            _: void align(std.atomic.cache_line),
            // NOTE: 之所以放在堆上而没有和allocator和last diage一样当成不变量放在外部，是因为
            // 将来可能将程序设计为服务式的，所有解析线程届时分析的repo可能会随之进行刷新。因此repo将来或许不是不变量。
            // 没有放在ParserStation内，虽然主类型与子类型类型相同。因为生存周期和子parser的不同，放在外面便于理解。
            repo: *c.git_repository,
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
        gpa_instance: vcaligner.gpa.Concurrent.Instance,
        diagnostics: diag.Diagnostics,
        // NOTE: 没有放在ParserStation内，虽然与主类型的相同，但生存周期和主parser的不同，放在外面便于理解。
        // 每个子解析线程都需要一个独立创建的repo，不应当复用。这是旧实现的一个重要问题，此重构实现修复。
        // [参见](https://gitlab.com/gitlab-org/libgit2/-/blob/master/docs/threading.md)
        repo: *c.git_repository,
        station: ParserStation,
        fn init(self: *SubParser, repo_path: [*c]const u8, last_diag: *diag.Diagnostic, channel: *Channel, slice_id: usize) !void {
            self.gpa_instance = .init();
            errdefer self.gpa_instance.deinit();
            const sub_parser_allocator = self.gpa_instance.gpac().allocator;
            self.diagnostics = .{ .arena = .init(sub_parser_allocator) };
            errdefer self.diagnostics.arena.deinit();
            self.repo = repo: {
                var sub_parser_block_repo: ?*c.git_repository = undefined;
                const git_error_code = c.git_repository_open_bare(&sub_parser_block_repo, repo_path);
                try c_helper.gitErrorCodeToZigError(git_error_code, last_diag);
                break :repo sub_parser_block_repo.?;
            };
            errdefer c.git_repository_free(self.repo);
            self.station = .init(channel, sub_parser_allocator);
            errdefer self.station.deinit();
            try vcaligner.crash_dump.reg("parser", slice_id + 1, &self.station.dumpable);
        }
        fn deinit(self: *SubParser, slice_id: usize) void {
            vcaligner.crash_dump.unreg("parser", slice_id + 1);
            self.station.deinit();
            c.git_repository_free(self.repo);
            self.diagnostics.arena.deinit();
            self.gpa_instance.deinit();
        }
    };
    pub fn init(n_subparserjobs: usize, repo: *c.git_repository, channel: *Channel, gpa: vcaligner.gpa.Concurrent, last_diag: *diag.Diagnostic) !ParsersHub {
        const raw = try gpa.allocator.alignedAlloc(u8, heap_align, heapSize(n_subparserjobs));
        errdefer gpa.allocator.free(raw);
        const heap_ptr: *align(heap_align.toByteUnits()) Header = @ptrCast(raw);
        heap_ptr.task_in_queue_count = .{ ._ = {}, .v = .init(0) };
        heap_ptr.main_parser_block = .{
            ._ = {},
            .repo = repo,
            .station = .init(channel, gpa.allocator),
        };
        errdefer heap_ptr.main_parser_block.station.deinit();
        try vcaligner.crash_dump.reg("parser", 0, &heap_ptr.main_parser_block.station.dumpable);
        errdefer vcaligner.crash_dump.unreg("parser", 0);
        const repo_path = c.git_repository_path(repo);
        const sub_parser_blocks: []SubParser = heap_ptr.subParserBlocksPtr()[0..n_subparserjobs];
        const sub_parser_blocks_init_result: union(enum) { success: void, failed: struct {
            err: (std.mem.Allocator.Error || c_helper.Libgit2Error || error{UnableToConstructDiagnostic}),
            slice_id: usize,
        } } = sub_parser_blocks_init: for (sub_parser_blocks, 0..) |*sub_parser_block, slice_id| {
            sub_parser_block.init(repo_path, last_diag, channel, slice_id) catch |err| break :sub_parser_blocks_init .{
                .failed = .{
                    .err = err,
                    .slice_id = slice_id,
                },
            };
        } else .success;
        return switch (sub_parser_blocks_init_result) {
            .failed => |failed| ret: {
                for (0..failed.slice_id) |reverse_slice_id| {
                    const slice_id = failed.slice_id - 1 - reverse_slice_id;
                    const sub_parser_block = &sub_parser_blocks[slice_id];
                    sub_parser_block.deinit(slice_id);
                }
                break :ret failed.err;
            },
            .success => .{
                .heap_ptr = heap_ptr,
                .main_parser_gpa = gpa,
                .main_parser_last_diag = last_diag,
                .n_subparserjobs = n_subparserjobs,
            },
        };
    }
    pub fn deinit(noalias self: *const ParsersHub, gpa: vcaligner.gpa.Concurrent) void {
        const sub_parser_blocks: []SubParser = self.heap_ptr.subParserBlocksPtr()[0..self.n_subparserjobs];
        var reverse_sub_parser_blocks_iter = std.mem.reverseIterator(sub_parser_blocks);
        while (reverse_sub_parser_blocks_iter.nextPtr()) |sub_parser_block| {
            sub_parser_block.deinit(reverse_sub_parser_blocks_iter.index);
        }
        vcaligner.crash_dump.unreg("parser", 0);
        self.heap_ptr.main_parser_block.station.deinit();
        const raw = @as([*]align(heap_align.toByteUnits()) u8, @ptrCast(self.heap_ptr))[0..heapSize(self.n_subparserjobs)];
        gpa.allocator.free(raw);
    }
    pub fn lctxFromThreadId(noalias self: *const ParsersHub, thread_id: usize) struct {
        vcaligner.gpa.Concurrent,
        *diag.Diagnostic,
        *c.git_repository,
        *ParserStation,
    } {
        if (thread_id == 0) return .{
            self.main_parser_gpa,
            self.main_parser_last_diag,
            self.heap_ptr.main_parser_block.repo,
            &self.heap_ptr.main_parser_block.station,
        };
        const sub_parser_block: *SubParser = &self.heap_ptr.subParserBlocksPtr()[0..heapSize(self.n_subparserjobs)][thread_id - 1];
        return .{
            sub_parser_block.gpa_instance.gpac(),
            &sub_parser_block.diagnostics.last_diagnostic,
            sub_parser_block.repo,
            &sub_parser_block.station,
        };
    }
};

// 各个解析线程的本地上下文。
const ParserStation = struct {
    producer_local: Queue.ProducerLocal,
    // 此arena是本解析线程的所有任务共用的一个arena，每个新任务开始时重置，主要保存一些递归解析过程中不会传递给最终消费者的当前任务临时缓存。
    // scratch的命名idea[来自](https://ziggit.dev/t/allocators-best-practices-anti-patterns/14043/5)
    // XXX: 当前的实现并没有更广泛地为了消除重复解析而加入整个线程级的缓存，如果采用了，那么此arena可能会改名且不再会在每次任务开始时重置。
    // （当然，若如此实现，也可能此scratch保留而额外增加线程级缓存与对应arena）
    current_task_scratch_arena: StArena,
    // `to_flush`为当前批次内容，flush过了就重置。
    // NOTE: 在当前实现中，`to_flush`作为批次，不会跨任务存在。之所以把它放在此上下文中，是考虑到未来可能更改实现使得它可以跨任务存在。
    to_flush: union(enum) {
        uninited: void,
        inited: Parsed,
    },
    // 这个东西完全是为了方便Dumpable去dump才定义的。实际上它完全和`to_flush`里的`commit_seq`重复。
    // TODO: 当dump机制被彻底弃用后，删除此字段。
    maybe_commit_seq_to_dump: ?CommitSeq,
    // 当全局崩溃时，打印相关信息。目前打印arena分配的空间大小。
    // TODO: 此机制终将被彻底弃用。
    dumpable: vcaligner.CrashDump.Dumpable,
    pub fn init(channel: *Channel, allocator: std.mem.Allocator) ParserStation {
        return .{
            .producer_local = channel.mpsc_queue_ref.initProducerLocal(),
            .current_task_scratch_arena = .init(allocator),
            .to_flush = .uninited,
            .maybe_commit_seq_to_dump = null,
            .dumpable = .{ .dumpFn = dumpFn },
        };
    }
    pub fn deinit(self: *ParserStation) void {
        switch (self.to_flush) {
            .uninited => {},
            .inited => |*parsed| parsed.deinit(),
        }
        self.current_task_scratch_arena.deinit();
        self.* = undefined;
    }
    fn dumpFn(dumpable: *vcaligner.CrashDump.Dumpable) void {
        const parsing: *ParserStation = @alignCast(@fieldParentPtr("dumpable", dumpable));
        // TODO：弃用CrashDump！崩溃时打印，会由崩溃线程打印其它线程的信息。此处的信息获取存在数据竞争。CrashDump应当被完全废弃。
        std.log.info("task capacity: {d}\n", .{parsing.current_task_scratch_arena.queryCapacity()});
        if (parsing.maybe_commit_seq_to_dump) |commit_seq_to_dump| {
            std.log.info("commit_seq: {d}\n", .{commit_seq_to_dump.toNative()});
        }
    }
};

// zig线程的`spawn`允许线程的任务函数有错误返回值。但是，它的实际效果并不美好：出现的错误会报告日志，但是不会对主线程产生丝毫影响，主线程无法感知到出错。
// 因此，相比主线程无法得知解析线程出错，还不如出错就崩溃。
pub fn mainParseTaskTakeRepo(
    repo: *c.git_repository,
    channel: *Channel,
    n_subparserjobs: usize,
    commit_registry: *CommitRegistry,
) void {
    // XXX: 此处的`main_parse_diagnostics`会进行某种复用，详见`Parsers`。另一种更简单的设计是分别使用两个diagnostics对象，但我停不下来了。
    // TODO: 经过仔细思考：当前的诊断模式是反模式，正确的模式是依赖注入的错误处理上下文。
    // 通过定制的错误处理上下文逻辑，辅以合理的错误处理传参规范，可以实现当前诊断模式的一切行为，且具体行为由错误处理上下文而非子模块自己去做。
    // 将来应当直接替换，且错误处理上下文极有可能由调用者传入。
    var main_parser_gpa_instance: vcaligner.gpa.Concurrent.Instance = .init();
    defer main_parser_gpa_instance.deinit();
    const gpa = main_parser_gpa_instance.gpac();
    var main_parse_diagnostics: diag.Diagnostics = .{ .arena = .init(gpa.allocator) };
    defer main_parse_diagnostics.arena.deinit();
    const last_diag = &main_parse_diagnostics.last_diagnostic;
    (main_parse_ret: {
        mainParseTakeRepo(
            repo,
            channel,
            n_subparserjobs,
            commit_registry,
            gpa,
            last_diag,
        ) catch |err| {
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

pub fn mainParseTakeRepo(
    repo: *c.git_repository,
    channel: *Channel,
    n_subparserjobs: usize,
    commit_registry: *CommitRegistry,
    gpa: vcaligner.gpa.Concurrent,
    last_diag: *diag.Diagnostic,
) !void {
    defer c.git_repository_free(repo);
    // 主解析线程的任务错误都需要确保通知写线程停止以避免写线程死锁。
    defer channel.notifyConsumerDone();
    const odb: *c.git_odb = blk: {
        var odb: ?*c.git_odb = undefined;
        const git_error_code = c.git_repository_odb(&odb, repo);
        try c_helper.gitErrorCodeToZigError(git_error_code, last_diag);
        break :blk odb.?;
    };
    defer c.git_odb_free(odb);
    var ctx: IndexBuilderCbPayload = .{
        .odb = odb,
        .commit_registry = commit_registry,
        .channel = channel,
        .pending_tasks_backpressure = n_subparserjobs * backpressure_multiplier: {
            break :backpressure_multiplier 8;
        },
        .parsers_ctx = undefined,
        .commit_meta_batch_to_flush = .uninited,
        .pool = undefined,
        .wait_group = .{},
    };
    // 正常路径`commit_meta_batch_to_flush`总是会被flush为uninited。为错误路径析构。
    defer switch (ctx.commit_meta_batch_to_flush) {
        .uninited => {},
        .inited => |*to_flush| to_flush.deinit(),
    };
    ctx.parsers_ctx = try .init(n_subparserjobs, repo, channel, gpa, last_diag);
    defer ctx.parsers_ctx.deinit(gpa);
    try ctx.pool.init(.{ .allocator = gpa.allocator, .n_jobs = n_subparserjobs, .track_ids = true });
    defer ctx.pool.deinit();
    // TODO: 在报错的情况下，真的还需要把堆积的任务做完吗？预测如果升级到0.16，`defer`内的逻辑需要修改为取消，而此处的逻辑不再放在`defer`内。
    defer ctx.pool.waitAndWork(&ctx.wait_group);
    const git_error_code_or_customized_error_code = c.git_odb_foreach(odb, index_builder_cb, &ctx);
    if (git_error_code_or_customized_error_code > 0) {
        const customized_error_enum: IndexBuilderCbCustomizedErrorEnum = .fromBackingInt(git_error_code_or_customized_error_code);
        return customized_error_enum.toError();
    }
    try c_helper.gitErrorCodeToZigError(git_error_code_or_customized_error_code, last_diag);
    switch (ctx.commit_meta_batch_to_flush) {
        .inited => |*to_flush| {
            flush_commit_meta_batch(to_flush, channel, &ctx.parsers_ctx.heap_ptr.main_parser_block.station.producer_local);
            ctx.commit_meta_batch_to_flush = .uninited;
        },
        .uninited => {},
    }
}

// NOTE: 依个人风格，一般不把可变内容与不可变内容集中在一个结构体中放置。
// 但这是特殊情况，因为这是一个用于C系函数的回调payload结构体，因此采用混合结构体的模式。
const IndexBuilderCbPayload = struct {
    odb: *c.git_odb,
    commit_registry: *CommitRegistry,
    channel: *Channel,
    pending_tasks_backpressure: usize,
    parsers_ctx: ParsersHub,
    commit_meta_batch_to_flush: union(enum) {
        uninited: void,
        inited: CommitMeta.Batch,
    },
    pool: vcaligner.Pool,
    wait_group: std.Thread.WaitGroup,
};
const IndexBuilderCbCustomizedError = std.mem.Allocator.Error;
const IndexBuilderCbCustomizedErrorEnum = vcaligner.ErrorEnumFromErrorSet(IndexBuilderCbCustomizedError, c_int, 1, 1);
// NOTE: 关于错误返回值：由于所有的git_error_code都小于0，我们约定小于0的是git_error_code，大于0的是自定义错误。
fn index_builder_cb(id: [*c]const c.git_oid, payload: ?*anyopaque) callconv(.c) c_int {
    var ctx: *IndexBuilderCbPayload = @ptrCast(@alignCast(payload.?));
    const customized_error = main_logic_customized_error: {
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
        ctx.commit_registry.map.putNoClobber(ctx.commit_registry.gpa_instance.gpao().allocator, id.*, {}) catch |err| {
            std.log.err("Commit regisistry put no clobber failed.\n", .{});
            break :main_logic_customized_error err;
        };
        append_commit_meta: {
            const to_flush = &ctx.commit_meta_batch_to_flush;
            switch (to_flush.*) {
                .inited => {},
                .uninited => {
                    to_flush.* = .{ .inited = .{ .gpa_instance = .init(), .batch = undefined } };
                    errdefer {
                        to_flush.inited.gpa_instance.deinit();
                        to_flush.* = .uninited;
                    }
                    to_flush.inited.batch = std.ArrayList(CommitMeta).initCapacity(to_flush.inited.gpa_instance.gpao().allocator, flush_threshold: {
                        // XXX: 当前设计为硬编码。或改为用户配置。
                        break :flush_threshold 512;
                    }) catch |err| break :main_logic_customized_error err;
                },
            }
            to_flush.inited.batch.appendAssumeCapacity(.{
                .commit_hash = id.*,
                .commit_seq = commit_seq,
            });
            if (to_flush.inited.batch.items.len == to_flush.inited.batch.capacity) {
                flush_commit_meta_batch(
                    &to_flush.inited,
                    ctx.channel,
                    &ctx.parsers_ctx.heap_ptr.main_parser_block.station.producer_local,
                );
                to_flush.* = .uninited;
            }
            break :append_commit_meta;
        }
        // 在添加线程池任务前，检查`task_in_queue_count`。若已满，自己也来帮忙执行。
        const task_in_queue_count = ctx.parsers_ctx.heap_ptr.task_in_queue_count.v.fetchAdd(1, .acquire);
        if (task_in_queue_count > ctx.pending_tasks_backpressure) help_do_work: {
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
        // NOTE: 为什么此处使用`@call`？为了确保`.always_inline`起作用。为什么这里必须内联？因为此处的`ctx.parsers_ctx`必须拷贝。
        // 考虑到zig将要移除PRO，此处的拷贝会在内部进行一次重复，这令我感到不满。因此选择必定内联来消除此次重复，因为subParseTask在源码中只在此处被调用。
        @call(.always_inline, vcaligner.Pool.spawnWgId, .{
            &ctx.pool,
            &ctx.wait_group,
            subParseTask,
            .{ ctx.parsers_ctx, id.*, commit_seq, ctx.channel },
        });
        return 0;
    };
    std.debug.assert(IndexBuilderCbCustomizedError == @TypeOf(customized_error));
    const customized_error_enum: IndexBuilderCbCustomizedErrorEnum = .fromError(customized_error);
    return customized_error_enum.toBackingInt();
}

fn flush_commit_meta_batch(to_flush: *CommitMeta.Batch, channel: *Channel, producer_local: *Queue.ProducerLocal) void {
    const ticket, const to_produce: *MsgToWriter = channel.claimProduce(producer_local, null);
    defer channel.publishProducedUnsafe(ticket);
    // ArenaAllocator和ArrayList经过源码验证，直接拷贝均安全。
    to_produce.* = .{ .commit_meta = to_flush.* };
    to_flush.* = undefined;
}

pub fn subParseTask(
    thrd_id: usize,
    ctx: ParsersHub,
    commit_hash: c.git_oid,
    commit_seq: vcaligner.rocksdb_custom.CommitSeq,
    channel: *Channel,
) void {
    // 进入解析，降低积压的`task_in_queue_count`
    _ = ctx.heap_ptr.task_in_queue_count.v.fetchSub(1, .release);
    const gpa, const last_diag, const repo, const lctx = ctx.lctxFromThreadId(thrd_id);
    _ = gpa;
    defer {
        if (!lctx.current_task_scratch_arena.reset(.retain_capacity)) {
            std.log.warn("Retain capacity failed, free all", .{});
        }
    }
    // 交由写线程释放。
    lctx.maybe_commit_seq_to_dump = commit_seq;

    (main_logic: {
        const commit: *c.git_commit = blk: {
            var commit: ?*c.git_commit = undefined;
            const git_error_code = c.git_commit_lookup(&commit, repo, &commit_hash);
            c_helper.gitErrorCodeToZigError(git_error_code, last_diag) catch |err| break :main_logic err;
            break :blk commit.?;
        };
        defer c.git_commit_free(commit);
        const tree: *c.git_tree = blk: {
            var tree: ?*c.git_tree = undefined;
            const git_error_code = c.git_commit_tree(&tree, commit);
            c_helper.gitErrorCodeToZigError(git_error_code, last_diag) catch |err| break :main_logic err;
            break :blk tree.?;
        };
        defer c.git_tree_free(tree);
        parse_tree(tree, repo, lctx, &@as([0]u8, .{}), commit_seq, channel) catch |err| break :main_logic err;
        switch (lctx.to_flush) {
            .inited => |*parsed| {
                flush_relation_batch(parsed, channel, &lctx.producer_local);
                lctx.to_flush = .uninited;
            },
            .uninited => {},
        }
        break :main_logic {};
    }) catch |err| {
        const diagnostics: *diag.Diagnostics = @alignCast(@fieldParentPtr("last_diagnostic", last_diag));
        diagnostics.log_all(err);
        diagnostics.clear();
        vcaligner.crash_dump.dumpAndCrash(@src());
    };
}

fn parse_tree(tree: *const c.git_tree, repo: *c.git_repository, lctx: *ParserStation, base_path: []const u8, commit_seq: vcaligner.rocksdb_custom.CommitSeq, channel: *Channel) !void {
    const entry_count = c.git_tree_entrycount(tree);
    for (0..entry_count) |i| {
        const entry = c.git_tree_entry_byindex(tree, i).?;
        const entry_type = c.git_tree_entry_type(entry);
        const entry_oid: *const c.git_oid = c.git_tree_entry_id(entry);
        switch (entry_type) {
            c.GIT_OBJECT_TREE => deeper: {
                const subtree: *c.git_tree = blk: {
                    var subtree: ?*c.git_tree = undefined;
                    // 对于查找过程，报错是一个正常现象：空目录就会报错，因此无需错误退出。
                    if (c.git_tree_lookup(&subtree, repo, entry_oid) != 0) break :deeper;
                    break :blk subtree.?;
                };
                defer c.git_tree_free(subtree);
                const child_path = blk: {
                    const entry_name = c.git_tree_entry_name(entry);
                    const entry_name_slice: []const u8 = std.mem.span(entry_name);
                    if (base_path.len == 0) {
                        break :blk try lctx.current_task_scratch_arena.allocator().dupe(u8, entry_name_slice);
                    }
                    break :blk try std.fmt.allocPrintSentinel(lctx.current_task_scratch_arena.allocator(), "{s}/{s}", .{ base_path, entry_name_slice }, 0);
                };
                defer lctx.current_task_scratch_arena.allocator().free(child_path);
                try parse_tree(subtree, repo, lctx, child_path, commit_seq, channel);
            },
            c.GIT_OBJECT_BLOB => {
                append_relation: {
                    var to_flush_arena: vcaligner.StArena = undefined;
                    switch (lctx.to_flush) {
                        .uninited => {
                            lctx.to_flush = .{ .inited = .{
                                .gpa_instance = .init(),
                                .arena_state = undefined,
                                .commit_seq = commit_seq,
                                .pairs = undefined,
                            } };
                            errdefer {
                                lctx.to_flush.inited.gpa_instance.deinit();
                                lctx.to_flush = .uninited;
                            }
                            to_flush_arena = .init(lctx.to_flush.inited.gpa_instance.gpao().allocator);
                            errdefer to_flush_arena.deinit();
                            lctx.to_flush.inited.pairs = try .initCapacity(to_flush_arena.allocator(), flush_threshold: {
                                // XXX: 当前设计为硬编码。或改为用户配置。
                                break :flush_threshold 512;
                            });
                            errdefer comptime unreachable;
                        },
                        .inited => |*parsed| to_flush_arena = parsed.arena_state.promote(parsed.gpa_instance.gpao().allocator),
                    }
                    defer lctx.to_flush.inited.arena_state = to_flush_arena.state;
                    // 不同之处在于此full path将移交writer，应使用to flush的arena且不会再释放。
                    const full_path = blk: {
                        const entry_name = c.git_tree_entry_name(entry);
                        const entry_name_slice: []const u8 = std.mem.span(entry_name);
                        if (base_path.len == 0) {
                            break :blk try to_flush_arena.allocator().dupe(u8, entry_name_slice);
                        }
                        break :blk try std.fmt.allocPrintSentinel(to_flush_arena.allocator(), "{s}/{s}", .{ base_path, entry_name_slice }, 0);
                    };
                    errdefer comptime unreachable;
                    lctx.to_flush.inited.pairs.appendAssumeCapacity(.{
                        .path = full_path,
                        .blob_hash = entry_oid.*,
                    });
                    break :append_relation;
                }
                if (lctx.to_flush.inited.pairs.items.len == lctx.to_flush.inited.pairs.capacity) {
                    flush_relation_batch(&lctx.to_flush.inited, channel, &lctx.producer_local);
                    lctx.to_flush = .uninited;
                }
            },
            else => {},
        }
    }
}

fn flush_relation_batch(to_flush: *Parsed, channel: *Channel, producer_local: *Queue.ProducerLocal) void {
    const ticket, const to_produce: *MsgToWriter = channel.claimProduce(producer_local, null);
    defer channel.publishProducedUnsafe(ticket);
    // ArenaAllocator和ArrayList经过源码验证，直接拷贝均安全。
    to_produce.* = .{ .parsed = to_flush.* };
    to_flush.* = undefined;
}
