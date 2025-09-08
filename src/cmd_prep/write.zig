const std = @import("std");
const PrepRunner = @import("PrepRunner.zig");
const PathSeq = PrepRunner.PathSeq;
const gvca = @import("gvca");
const c = gvca.c_helper.c;
const diag = gvca.diag;

pub const write_batch_threshold = 512;

// write线程：完成对于数据库初创时的默认列族、pi2p列族、ci2c列族的写入。此过程与解析线程们同时进行，是mpsc的c端。
// 此过程对于rocksdb仅写入，无压缩。压缩为写入完毕的后继内容，回归主线程进行。
pub fn task(ctx: *PrepRunner) void {
    // 写线程本地分配器。都是c分配器。
    const allocator = gvca.getAllocator();
    const diagnostics_arena = std.heap.ArenaAllocator.init(allocator);
    defer diagnostics_arena.deinit();
    var diagnostics: diag.Diagnostics = .{ .arena = diagnostics_arena };
    const last_diag = &diagnostics.last_diagnostic;
    _ = last_diag;

    // 所有线程公用：对于`rocksdb_writebatch_mergev_cf`，`keys_list_sizes`永远相同，因此总是给write_batch看相同的内容。
    // `values_list_sizes`同理。注意它们都仅仅适用于`rocksdb_writebatch_mergev_cf`，`writebatch`对默认列族以外的操作不适用
    const keys_list_sizes: [write_batch_threshold * 2]usize = @splat(@sizeOf(PrepRunner.Parsed.KeyBuf));
    const values_list_sizes: [write_batch_threshold * 2]usize = @splat(@sizeOf(PrepRunner.CommitSeq));

    // rocksdb 配置调优……
    var err_cstr: ?[*:0]u8 = null;

    // 由于C API未支持`SetDBOptions`，因此每当需要修改一些数据库基础配置时（例如flush/compactions线程数），选择关闭数据库重建配置以后重新打开。
    // 此处为首次创建数据库的配置。线程全部用于flush，禁止compaction。
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
        c.rocksdb_options_set_merge_operator(db_options, ctx.writer.merge_operator_state.createFixedBinaryAppendMergeOperater());
        // 注：当options已经被用于打开rocksdb以后，rocksdb内部有此配置的拷贝，对options的直接修改不会影响rocksdb。
        // 虽然后续可以用`rocksdb_set_options`和`rocksdb_set_options_cf`中途修改各默认列族的行为。
        // 但是，C API不支持`SetDBOptions`，也就是修改数据库本体的操作。后续必须关闭数据库再重新打开。
        break :blk db_options.?;
    };
    defer {
        std.log.info("db options destroy...\n", .{});
        c.rocksdb_options_destroy(db_options);
    }

    const db = blk: {
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
    const cf_pi_b_cis = c.rocksdb_get_default_column_family_handle(db).?;
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
    const cf_pi_p = blk: {
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
    const cf_ci_c = blk: {
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

    // XXX: 如果阻塞，添加一些异步执行的内容，比如整理当前的path排序？若如此做，后续部分逻辑需要改动。
    while (ctx.channel.claimConsume(&consumer_local, null)) |lease| {
        const ticket, const parsed: *PrepRunner.Parsed = lease;
        // mpsc队列中消费者不比生产者，生产者写入过程需要尽可能快否则消费者可能卡在慢生产者后面。消费者慢点卡着没逝的。
        defer ctx.channel.releaseConsumedUnsafe(ticket);
        // XXX: 原计划有跨任务的`writebatch`堆积。最终放弃，如果需要跨任务堆积`writebatch`，那么各个任务来的arena就必须延迟释放。
        // 还需要额外管理arena的保存，很麻烦，而且一定要堆那么多才一次性写入未必总是好的，毕竟是无序写。

        // 如果`commit_hash`非空，写入一个commit id- commit对
        if (parsed.commit_hash) |*commit_hash| {
            std.log.info("commit_seq: {x}\n", .{parsed.commit_seq.*});
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
            const get_or_put_result = ctx.writer.path_registry.map.getOrPut(ctx.writer.path_registry.arena.allocator(), parsed_unit.path) catch |err| {
                diagnostics.log_all(err);
                diagnostics.clear();
                std.process.abort();
            };
            if (!get_or_put_result.found_existing) {
                std.log.info("path id: {d}\n", .{get_or_put_result.index});
                std.log.info("path: {s}\n", .{parsed_unit.path});
                std.log.info("path ptr: {*}\n", .{parsed_unit.path.ptr});
                std.log.info("key ptr: {*}\n", .{get_or_put_result.key_ptr});
                std.log.info("key ptr ptr: {*}\n", .{get_or_put_result.key_ptr.*.ptr});
                // 注意！`getOrPut`会直接把我们用于比较的`parsed_unit.path`作为键。但是`parsed_unit.path`的生存周期实际上并不够！
                // 因此，我们需要重新设置一个生命周期安全的新key，也就是将当前的`parsed_unit.path`用hash map自己的分配器重新拷贝一份。
                // 虽然文档让我们不要修改键，但我想我知道我们现在在做什么。
                get_or_put_result.key_ptr.* = std.mem.Allocator.dupe(ctx.writer.path_registry.arena.allocator(), u8, parsed_unit.path) catch |err| {
                    diagnostics.log_all(err);
                    diagnostics.clear();
                    std.process.abort();
                };
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
            &keys_list_sizes,
            @intCast(parsed.values_list.len),
            @ptrCast(parsed.values_list.ptr),
            &values_list_sizes,
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
}
