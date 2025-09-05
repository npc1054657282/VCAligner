const std = @import("std");
const PrepRunner = @import("PrepRunner.zig");
const gvca = @import("gvca");
const c = gvca.c_helper.c;
const diag = gvca.diag;

pub const write_batch_threshold = 512;
// Array hash map的`count()`返回类型为`usize`，与`hash map`的`u32`有显著不同。这是因为涉及索引，用`usize`有很大方便。
// 尽管path多数情况下最大值可能不如commit多。简单起见PathSeq设置为符合ArrayHashMap要求的usize。
pub const PathSeq = usize;
const PathRegistry = struct {
    // ArrayHashMap提供排序功能，应当使用它
    map: std.StringArrayHashMapUnmanaged(struct {
        // 初次插入时的index。插入同时记录，因为后续排序时，原始index会丢失
        index: PathSeq,
        // 在写入过程中不记录此值。在全部写入完毕以后，遍历一遍所有的key统计此值。最后排序的依据。
        // XXX: 在内存中为每个path都记录一个它的blob的hashmap。怀疑其可行性，宁肯全部写入完毕以后再遍历rocksdb数据库。
        blob_cnt: usize,
    }),
    arena: std.heap.ArenaAllocator,
};

pub fn task(ctx: *PrepRunner) void {
    // 写线程本地分配器。都是c分配器。
    const allocator = gvca.getAllocator();
    const diagnostics_arena = std.heap.ArenaAllocator.init(allocator);
    defer diagnostics_arena.deinit();
    var diagnostics: diag.Diagnostics = .{ .arena = diagnostics_arena };
    const last_diag = &diagnostics.last_diagnostic;
    _ = last_diag;

    // rocksdb 配置调优……

    // 默认列族需要merge operator，在后面追加commit。
    var err_cstr: ?[*:0]u8 = null;
    var merge_operator_state: FixedBinaryAppendMergeOperaterState = .init(allocator);
    defer {
        std.log.info("merge operator state deinit...\n", .{});
        merge_operator_state.deinit();
    }
    // rocksdb相关对象创建的C API内部是`new`，走的C++异常机制，不会把错误结果传播，因此判空无意义。
    // 数据库以及默认列族相关配置
    const db_options = blk: {
        const db_options = c.rocksdb_options_create();
        c.rocksdb_options_set_create_if_missing(db_options, 1);
        c.rocksdb_options_set_error_if_exists(db_options, 1); // 如果db已存在，报错。
        // 设置最大环境线程储量。
        c.rocksdb_options_increase_parallelism(db_options, @intCast(ctx.n_jobs));
        // 目前仅单线程写入，获取一点微小的性能提升。注：因为全是merge操作，因此`inplace_update_support`无用，不予配置。
        c.rocksdb_options_set_allow_concurrent_memtable_write(db_options, 0);

        // 此配置为关键混合配置：同时影响数据库与默认列族的行为。
        // FAQ说这个函数会使用vector memtable。如果是这样的话，对我这种乱序写入的场景就不适合了。
        // 但是，所幸的是，看了[源码](https://github.com/facebook/rocksdb/blob/a34683bf543cc3eb151d08eeac00791862acd4d6/options/options.cc#L478-L519)
        // 实际没有修改memtable使用类型的行为，仅仅是全部写入L0以及禁止自动压缩。这些行为都是我需要的，可以放心使用。
        // 这个行为会设置`flush`线程为4。不用担心`flush`线程数影响parser等其他线程，因为这是I/O密集线程，不怎么影响计算线程。
        c.rocksdb_options_prepare_for_bulk_load(db_options);

        // 以下为默认列族相关配置
        // 一定要小心，此处神坑！这两个东西进入options时都会变成`shared ptr`并且移交所有权！
        // 千万不要调用C API提供的`rocksdb_slicetransform_destroy`和`rocksdb_mergeoperator_destroy`！
        // 默认列族以path-id为前缀。不使用布隆过滤器，因为后续使用数据库的时候基本没有需要检查无效的key的情况。
        c.rocksdb_options_set_prefix_extractor(db_options, c.rocksdb_slicetransform_create_fixed_prefix(@sizeOf(PathSeq)));
        c.rocksdb_options_set_merge_operator(db_options, merge_operator_state.createFixedBinaryAppendMergeOperater());
        // 注：当options已经被用于打开rocksdb以后，rocksdb内部有此配置的拷贝，对options的直接修改不会影响rocksdb。
        // 虽然后续可以用`rocksdb_set_options`和`rocksdb_set_options_cf`中途修改各默认列族的行为。
        // 但是，C API不支持`SetDBOptions`，也就是修改数据库本体的操作。后续必须关闭数据库再重新打开。
        break :blk db_options.?;
    };
    defer {
        std.log.info("db options destroy...\n", .{});
        c.rocksdb_options_destroy(db_options);
    }

    var db = blk: {
        const db = c.rocksdb_open(db_options, ctx.rocksdb_output, @ptrCast(&err_cstr));
        if (err_cstr) |ecstr| {
            std.log.err("rocksdb create failed! {s}\n", .{std.mem.span(ecstr)});
            std.process.abort();
        }
        break :blk db.?;
    };
    defer {
        std.log.info("rocksdb close...\n", .{});
        c.rocksdb_close(db);
    }

    // 默认列族：键是path_index-blob，值由多个commit_index组成，需要前缀提取器。
    var cf_pi_b_cis = c.rocksdb_get_default_column_family_handle(db).?;
    defer {
        std.log.info("default handle destroy...\n", .{});
        c.rocksdb_column_family_handle_destroy(cf_pi_b_cis);
    }

    // 为其它列族设置单独的默认配置（它们不需要前缀提取器和merge operator）
    // 尽管可能的写入方式仍然存在一些区别，简单考虑依旧使用相同的配置。
    const cf_options = blk: {
        const cf_options = c.rocksdb_options_create();
        c.rocksdb_options_prepare_for_bulk_load(cf_options);
        break :blk cf_options.?;
    };
    defer {
        std.log.info("cf options destroy...\n", .{});
        c.rocksdb_options_destroy(cf_options);
    }

    // 键 path_index - 值 path 列族
    // 由于path index 由本写者线程自己维护，因此这个列族一定可以确保有序写入，理论上完全可以通过sstfilewriter写入。
    // 不是主要性能问题来源，暂不考虑增加复杂度。
    var cf_pi_p = blk: {
        const cf_pi_p = c.rocksdb_create_column_family(db, cf_options, "pi2p", @ptrCast(&err_cstr));
        if (err_cstr) |ecstr| {
            std.log.err("rocksdb create column family 'ci2c' failed! {s}\n", .{std.mem.span(ecstr)});
            std.process.abort();
        }
        break :blk cf_pi_p.?;
    };
    defer {
        std.log.info("pi2p handle destroy...\n", .{});
        c.rocksdb_column_family_handle_destroy(cf_pi_p);
    }

    // 键 commit_index - 值 commit 列族
    // 由于commit index由任务发布者线程创建，这个列族无法确保有序写入，除非在写本地线程重新维护一套seq方案而不使用任务发布者提出的方案。
    // XXX: 另一个方案是，和path rank一样，不在中途写入，而是由任务发布者保存seq，且在全部写入完毕后从任务发布者处接收并一次性写入。
    // 替代方案优化性能有限，暂不考虑。
    var cf_ci_c = blk: {
        const cf_ci_c = c.rocksdb_create_column_family(db, cf_options, "ci2c", @ptrCast(&err_cstr));
        if (err_cstr) |ecstr| {
            std.log.err("rocksdb create column family 'ci2c' failed! {s}\n", .{std.mem.span(ecstr)});
            std.process.abort();
        }
        break :blk cf_ci_c.?;
    };
    defer {
        std.log.info("ci2c handle destroy...\n", .{});
        c.rocksdb_column_family_handle_destroy(cf_ci_c);
    }

    const woptions = blk: {
        const woptions = c.rocksdb_writeoptions_create();
        c.rocksdb_writeoptions_disable_WAL(woptions, 1);
        break :blk woptions.?;
    };
    defer {
        std.log.info("write options destroy...\n", .{});
        c.rocksdb_writeoptions_destroy(woptions);
    }

    const wb = c.rocksdb_writebatch_create().?;
    defer {
        std.log.info("writebatch destroy...\n", .{});
        c.rocksdb_writebatch_destroy(wb);
    }

    var consumer_local = ctx.channel.mpsc_queue_ref.initConsumerLocal();
    // 一个写线程本地的ArrayHashMap，
    var path_registry: PathRegistry = .{ .map = .empty, .arena = .init(allocator) };
    defer {
        path_registry.map.deinit(path_registry.arena.allocator());
        path_registry.arena.deinit();
    }
    // XXX: 如果阻塞，添加一些异步执行的内容，比如整理当前的path排序？若如此做，后续部分逻辑需要改动。
    while (ctx.channel.claimConsume(&consumer_local, null)) |lease| {
        const ticket, const parsed: *PrepRunner.Parsed = lease;
        // mpsc队列中消费者不比生产者，生产者写入过程需要尽可能快否则消费者可能卡在慢生产者后面。消费者慢点卡着没逝的。
        defer ctx.channel.releaseConsumedUnsafe(ticket);
        // XXX: 原计划有跨任务的`writebatch`堆积。最终放弃，如果需要跨任务堆积`writebatch`，那么各个任务来的arena就必须延迟释放。
        // 还需要额外管理arena的保存，很麻烦，而且一定要堆那么多才一次性写入未必总是好的，毕竟是无序写。

        // 如果`commit_hash`非空，写入一个commit id- commit对
        if (parsed.commit_hash) |*commit_hash| {
            std.log.info("commit_seq: {d}\n", .{parsed.commit_seq.*});
            std.log.info("commit_hash: {x}\n", .{commit_hash.id});
            c.rocksdb_writebatch_put_cf(
                wb,
                cf_ci_c,
                @ptrCast(parsed.commit_seq),
                @sizeOf(PrepRunner.CommitSeq),
                @ptrCast(&commit_hash.id),
                @sizeOf(@TypeOf(commit_hash.id)),
            );
        }
        // 就地修改`parsed_unit`中的`key`
        for (parsed.parsed_units.items) |*parsed_unit| {
            const get_or_put_result = path_registry.map.getOrPut(path_registry.arena.allocator(), parsed_unit.path) catch |err| {
                diagnostics.log_all(err);
                diagnostics.clear();
                std.process.abort();
            };
            if (!get_or_put_result.found_existing) {
                get_or_put_result.value_ptr.index = std.mem.nativeToBig(PathSeq, get_or_put_result.index);
                // 新的path id - path对，写入writebatch
                parsed_unit.key.path_seq = get_or_put_result.value_ptr.index;
                c.rocksdb_writebatch_put_cf(
                    wb,
                    cf_pi_p,
                    @ptrCast(&parsed_unit.key.path_seq),
                    @sizeOf(PathSeq),
                    @ptrCast(parsed_unit.path.ptr),
                    parsed_unit.path.len,
                );
            } else parsed_unit.key.path_seq = get_or_put_result.value_ptr.index;
        }
        // 检查是否超出阈值。超出阈值立即写入memtable。
        if (c.rocksdb_writebatch_count(wb) > write_batch_threshold) {
            c.rocksdb_write(db, woptions, wb, @ptrCast(&err_cstr));
            if (err_cstr) |ecstr| {
                std.log.err("rocksdb write failed! {s}\n", .{std.mem.span(ecstr)});
                std.process.abort();
            }
        }
        // 批量merge入默认列族
        c.rocksdb_writebatch_mergev_cf(
            wb,
            cf_pi_b_cis,
            @intCast(parsed.keys_list.items.len),
            @ptrCast(parsed.keys_list.items.ptr),
            &ctx.keys_list_sizes,
            @intCast(parsed.values_list.len),
            @ptrCast(parsed.values_list.ptr),
            &ctx.values_list_sizes,
        );
        // 总是写入memtable
        c.rocksdb_write(db, woptions, wb, @ptrCast(&err_cstr));
        if (err_cstr) |ecstr| {
            std.log.err("rocksdb write failed! {s}\n", .{std.mem.span(ecstr)});
            std.process.abort();
        }
        // 销毁一切。
        parsed.arena.deinit();
    } else |_| {}
    // 后处理：修改配置不再启用 prepare for bulk load
    // 先确保可能写入的列族全部刷新到磁盘。
    const foptions = c.rocksdb_flushoptions_create().?;
    defer {
        std.log.info("flush options destroy...\n", .{});
        c.rocksdb_flushoptions_destroy(foptions);
    }
    c.rocksdb_flushoptions_set_wait(foptions, 1);
    flush_all: {
        var column_family = [_]?*c.struct_rocksdb_column_family_handle_t{
            cf_pi_b_cis,
            cf_pi_p,
            cf_ci_c,
        };
        c.rocksdb_flush_cfs(db, foptions, &column_family, column_family.len, @ptrCast(&err_cstr));
        if (err_cstr) |ecstr| {
            std.log.err("rocksdb flush failed! {s}\n", .{std.mem.span(ecstr)});
            std.process.abort();
        }
        break :flush_all;
    }
    // 由于C API没有对`SetDbOptions`的支持，因此只得关闭数据库后，根据修改后的配置重新打开。
    db, cf_pi_b_cis, cf_pi_p, cf_ci_c = reopen_db: {
        c.rocksdb_options_set_max_background_compactions(db_options, @intCast(ctx.n_jobs));
        c.rocksdb_options_set_max_background_flushes(db_options, 1);
        c.rocksdb_options_set_create_if_missing(db_options, 0);
        c.rocksdb_options_set_error_if_exists(db_options, 0);

        c.rocksdb_column_family_handle_destroy(cf_pi_b_cis);
        c.rocksdb_column_family_handle_destroy(cf_pi_p);
        c.rocksdb_column_family_handle_destroy(cf_ci_c);
        c.rocksdb_close(db);
        const column_family_names = [_][*:0]const u8{
            "default",
            "pi2p",
            "ci2c",
        };
        const column_family_options: [column_family_names.len]?*const c.rocksdb_options_t = .{
            db_options,
            cf_options,
            cf_options,
        };
        var column_family_handles: [column_family_names.len]?*c.rocksdb_column_family_handle_t = undefined;
        // 其他列族已经不再需要，但是打开的时候必须打开所有列族，否则就报失败。
        const new_db = c.rocksdb_open_column_families(
            db_options,
            ctx.rocksdb_output,
            column_family_names.len,
            @ptrCast(&column_family_names),
            &column_family_options,
            &column_family_handles,
            @ptrCast(&err_cstr),
        );
        if (err_cstr) |ecstr| {
            std.log.err("rocksdb reopen failed! {s}\n", .{std.mem.span(ecstr)});
            std.process.abort();
        }
        break :reopen_db .{ new_db.?, column_family_handles[0].?, column_family_handles[1].?, column_family_handles[2].? };
    };
    // 触发手动compaction（整个数据库）
    const compact_options = c.rocksdb_compactoptions_create();
    defer {
        std.log.info("compact options destroy...\n", .{});
        c.rocksdb_compactoptions_destroy(compact_options);
    }
    c.rocksdb_compact_range_opt(db, compact_options, null, 0, null, 0);
    // 等待compaction完成
    // XXX: 如果不必重新打开数据库的话，此处可以配置压缩前刷写数据库，或许可以不再需要前面手动flush。不过现在说这个有些晚了。
    const wait_for_compact_options = c.rocksdb_wait_for_compact_options_create().?;
    defer {
        std.log.info("wait for compact options destroy...\n", .{});
        c.rocksdb_wait_for_compact_options_destroy(wait_for_compact_options);
    }
    c.rocksdb_wait_for_compact(db, wait_for_compact_options, @ptrCast(&err_cstr));
    if (err_cstr) |ecstr| {
        std.log.err("rocksdb wait for compact failed! {s}\n", .{std.mem.span(ecstr)});
        std.process.abort();
    }

    // 另一种方案等待 Compaction 完成，为了保险起见，因为不熟悉`rocksdb_wait_for_compact`
    while (true) {
        var num_running: u64 = undefined;
        var err = c.rocksdb_property_int(db, "rocksdb.num-running-compactions", &num_running);
        if (err != 0) {
            std.log.err("rocksdb write failed! {d}\n", .{err});
            std.process.abort();
        }

        var pending: u64 = undefined;
        err = c.rocksdb_property_int(db, "rocksdb.compaction-pending", &pending);
        if (err != 0) {
            std.log.err("rocksdb write failed! {d}\n", .{err});
            std.process.abort();
        }

        if (num_running == 0 and pending == 0) {
            std.debug.print("Compaction completed.\n", .{});
            break;
        }
        std.debug.print("Waiting for compaction: running={d}, pending={d}\n", .{ num_running, pending });
        std.Thread.sleep(10 * std.time.ns_per_s); // 等待 10s
    }
    // 键 path_rank - 值 path_index 列族。
    // 这个列族的键需要在全部写入完毕以后重新遍历获取，仅适合在最后单独写入。
    const cf_pr_pi = blk: {
        const cf_pr_pi = c.rocksdb_create_column_family(db, cf_options, "pr2pi", @ptrCast(&err_cstr));
        if (err_cstr) |ecstr| {
            std.log.err("rocksdb create column family 'ci2c' failed! {s}\n", .{std.mem.span(ecstr)});
            std.process.abort();
        }
        break :blk cf_pr_pi.?;
    };
    defer {
        std.log.info("pr2pi handle destroy...\n", .{});
        c.rocksdb_column_family_handle_destroy(cf_pr_pi);
    }
    std.log.info("Create pr2pi OK.\n", .{});
}

const FixedBinaryAppendMergeOperaterState = struct {
    failed: [0]u8, // 当失败的时候返回其指针。
    pool1: std.heap.MemoryPoolExtra([@sizeOf(PrepRunner.CommitSeq) * 1]u8, .{}),
    pool2: std.heap.MemoryPoolExtra([@sizeOf(PrepRunner.CommitSeq) * 2]u8, .{}),
    pool4: std.heap.MemoryPoolExtra([@sizeOf(PrepRunner.CommitSeq) * 4]u8, .{}),
    pool8: std.heap.MemoryPoolExtra([@sizeOf(PrepRunner.CommitSeq) * 8]u8, .{}),
    pool16: std.heap.MemoryPoolExtra([@sizeOf(PrepRunner.CommitSeq) * 16]u8, .{}),
    pool32: std.heap.MemoryPoolExtra([@sizeOf(PrepRunner.CommitSeq) * 32]u8, .{}),
    pool64: std.heap.MemoryPoolExtra([@sizeOf(PrepRunner.CommitSeq) * 64]u8, .{}),
    pool128: std.heap.MemoryPoolExtra([@sizeOf(PrepRunner.CommitSeq) * 128]u8, .{}),
    pool256: std.heap.MemoryPoolExtra([@sizeOf(PrepRunner.CommitSeq) * 256]u8, .{}),
    pool512: std.heap.MemoryPoolExtra([@sizeOf(PrepRunner.CommitSeq) * 512]u8, .{}),
    pool1024: std.heap.MemoryPoolExtra([@sizeOf(PrepRunner.CommitSeq) * 1024]u8, .{}),
    allocator: std.mem.Allocator,
    fn init(allocator: std.mem.Allocator) FixedBinaryAppendMergeOperaterState {
        return .{
            .failed = .{},
            .pool1 = .init(allocator),
            .pool2 = .init(allocator),
            .pool4 = .init(allocator),
            .pool8 = .init(allocator),
            .pool16 = .init(allocator),
            .pool32 = .init(allocator),
            .pool64 = .init(allocator),
            .pool128 = .init(allocator),
            .pool256 = .init(allocator),
            .pool512 = .init(allocator),
            .pool1024 = .init(allocator),
            .allocator = allocator,
        };
    }
    fn deinit(self: *FixedBinaryAppendMergeOperaterState) void {
        self.pool1.deinit();
        self.pool2.deinit();
        self.pool4.deinit();
        self.pool8.deinit();
        self.pool16.deinit();
        self.pool32.deinit();
        self.pool64.deinit();
        self.pool128.deinit();
        self.pool256.deinit();
        self.pool512.deinit();
        self.pool1024.deinit();
    }
    fn create(self: *FixedBinaryAppendMergeOperaterState, len: usize) ![]u8 {
        const fitlen = std.math.ceilPowerOfTwo(usize, len) catch unreachable;
        return switch (fitlen) {
            @sizeOf(PrepRunner.CommitSeq) * 1 => try self.pool1.create(),
            @sizeOf(PrepRunner.CommitSeq) * 2 => try self.pool2.create(),
            @sizeOf(PrepRunner.CommitSeq) * 4 => try self.pool4.create(),
            @sizeOf(PrepRunner.CommitSeq) * 8 => try self.pool8.create(),
            @sizeOf(PrepRunner.CommitSeq) * 16 => try self.pool16.create(),
            @sizeOf(PrepRunner.CommitSeq) * 32 => try self.pool32.create(),
            @sizeOf(PrepRunner.CommitSeq) * 64 => try self.pool64.create(),
            @sizeOf(PrepRunner.CommitSeq) * 128 => try self.pool128.create(),
            @sizeOf(PrepRunner.CommitSeq) * 256 => try self.pool256.create(),
            @sizeOf(PrepRunner.CommitSeq) * 512 => try self.pool512.create(),
            @sizeOf(PrepRunner.CommitSeq) * 1024 => try self.pool1024.create(),
            else => try self.allocator.alloc(u8, len),
        };
    }
    fn destroy(self: *FixedBinaryAppendMergeOperaterState, ptr: [*c]u8, len: usize) void {
        const fitlen = std.math.ceilPowerOfTwo(usize, len) catch unreachable;
        switch (fitlen) {
            @sizeOf(PrepRunner.CommitSeq) * 1 => self.pool1.destroy(@ptrCast(@alignCast(ptr))),
            @sizeOf(PrepRunner.CommitSeq) * 2 => self.pool2.destroy(@ptrCast(@alignCast(ptr))),
            @sizeOf(PrepRunner.CommitSeq) * 4 => self.pool4.destroy(@ptrCast(@alignCast(ptr))),
            @sizeOf(PrepRunner.CommitSeq) * 8 => self.pool8.destroy(@ptrCast(@alignCast(ptr))),
            @sizeOf(PrepRunner.CommitSeq) * 16 => self.pool16.destroy(@ptrCast(@alignCast(ptr))),
            @sizeOf(PrepRunner.CommitSeq) * 32 => self.pool32.destroy(@ptrCast(@alignCast(ptr))),
            @sizeOf(PrepRunner.CommitSeq) * 64 => self.pool64.destroy(@ptrCast(@alignCast(ptr))),
            @sizeOf(PrepRunner.CommitSeq) * 128 => self.pool128.destroy(@ptrCast(@alignCast(ptr))),
            @sizeOf(PrepRunner.CommitSeq) * 256 => self.pool256.destroy(@ptrCast(@alignCast(ptr))),
            @sizeOf(PrepRunner.CommitSeq) * 512 => self.pool512.destroy(@ptrCast(@alignCast(ptr))),
            @sizeOf(PrepRunner.CommitSeq) * 1024 => self.pool512.destroy(@ptrCast(@alignCast(ptr))),
            else => self.allocator.free(ptr[0..len]),
        }
    }
    fn createFixedBinaryAppendMergeOperater(self: *FixedBinaryAppendMergeOperaterState) *c.rocksdb_mergeoperator_t {
        return c.rocksdb_mergeoperator_create(
            self,
            // destructor可以是空操作，但是不能没有。
            destructor,
            fullMerge,
            // 部分合并会增加多个小对象分配。完整对象栈的合并因为减少了内存分配量反而更高效。
            // 但是`partialMerge`的实现是必须的，而且C API没有合理的部分合并失败策略，只能正常实现。
            // [参考](https://github.com/johnzeng/rocksdb-doc-cn/blob/master/doc/Merge-Operator-Implementation.md#%E6%95%88%E7%8E%87%E7%9B%B8%E5%85%B3%E7%9A%84%E7%AC%94%E8%AE%B0)
            partialMerge,
            deleteValue,
            name,
        ).?;
    }
    fn destructor(state: ?*anyopaque) callconv(.c) void {
        _ = state;
        return;
    }
    fn fullMerge(
        state: ?*anyopaque,
        key: [*c]const u8,
        key_length: usize,
        existing_value: [*c]const u8,
        existing_value_length: usize,
        operands_list: [*c]const [*c]const u8,
        operands_list_length: [*c]const usize,
        num_operands: c_int,
        success: [*c]u8,
        new_value_length: [*c]usize,
    ) callconv(.c) [*c]u8 {
        const mem_pools: *FixedBinaryAppendMergeOperaterState = @ptrCast(@alignCast(state.?));
        _ = key;
        _ = key_length;
        const total_length = blk: {
            var tlen = if (existing_value != null) existing_value_length else 0;
            for (0..@intCast(num_operands)) |i| {
                tlen += operands_list_length[i];
            }
            break :blk tlen;
        };
        const result = mem_pools.create(total_length) catch {
            std.log.err("mem pool create failed! lotal length is {d}\n", .{total_length});
            success.* = 0;
            new_value_length.* = 0;
            // 分析C API源码发现merge失败时不会检查是否失败都会进行一次对`string`的赋值，如果返回`null`是未定义行为，于是借用state里的failed地址返回。
            return &mem_pools.failed;
        };

        var offset: usize = 0;
        if (existing_value != null) {
            @memcpy(result[offset..].ptr, existing_value[0..existing_value_length]);
            offset += existing_value_length;
        }
        for (0..@intCast(num_operands)) |i| {
            const operand = operands_list[i];
            const operand_len = operands_list_length[i];
            @memcpy(result[offset..].ptr, operand[0..operand_len]);
            offset += operand_len;
        }
        new_value_length.* = total_length;
        success.* = 1;
        return result.ptr;
    }
    fn partialMerge(
        state: ?*anyopaque,
        key: [*c]const u8,
        key_length: usize,
        operands_list: [*c]const [*c]const u8,
        operands_list_length: [*c]const usize,
        num_operands: c_int,
        success: [*c]u8,
        new_value_length: [*c]usize,
    ) callconv(.c) [*c]u8 {
        // 1.根据C语言的源码，`partialMerge`是不可不实现的，不实现就出问题。
        // 2.根据C语言源码，没有可靠的阻止`partialMerge`实现的失败策略，
        // 因为我看相关注释，如果想要阻止`partialMerge`，要求不改变`new_value`且返回失败。而C API源码实现不论是否成败都一定更新`new_value`。
        // 因此，只能尽可能让`partialMerge`成功，虽然每次这么做都需要一次大的内存拷贝，也属于无奈之举。
        return fullMerge(state, key, key_length, null, 0, operands_list, operands_list_length, num_operands, success, new_value_length);
    }
    fn deleteValue(state: ?*anyopaque, value: [*c]const u8, value_length: usize) callconv(.c) void {
        if (value_length == 0) return;
        const mem_pools: *FixedBinaryAppendMergeOperaterState = @ptrCast(@alignCast(state.?));
        // 神秘API设计：`deleteValue`钩子居然要求是个`const`指针，差点让我以为我用错了。检察源码发现居然真就是这么用的。
        mem_pools.destroy(@constCast(value.?), value_length);
    }
    fn name(state: ?*anyopaque) callconv(.c) [*c]const u8 {
        _ = state;
        return "FixedBinaryAppendMergeOperater";
    }
};
