const std = @import("std");
const PrepRunner = @import("PrepRunner.zig");
const gvca = @import("gvca");
const PathSeq = gvca.rocksdb_custom.PathSeq;
const BlobPathKey = gvca.rocksdb_custom.BlobPathKey;
const BlobPathSeq = gvca.rocksdb_custom.BlobPathSeq;
const CommitSeq = gvca.rocksdb_custom.CommitSeq;
const Key = gvca.rocksdb_custom.Key;
const c = gvca.c_helper.c;
const diag = gvca.diag;

pub const batch_threshold = 512;
pub const write_batch_threshold = 4096 - batch_threshold;

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

    var keys_buf: [write_batch_threshold + batch_threshold]Key = undefined;
    var keys_buf_cursor: usize = 0;

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
        c.rocksdb_options_increase_parallelism(db_options, @intCast(ctx.n_rocksdbjobs));
        // 目前仅单线程写入，获取一点微小的性能提升。注：因为全是merge操作，因此`inplace_update_support`无用，不予配置。
        c.rocksdb_options_set_allow_concurrent_memtable_write(db_options, 0);
        // 重要！默认无限制地打开文件，由于实际打开的文件数量有好几千，将导致无限制的内存提交，最终导致over commit。必须限制
        c.rocksdb_options_set_max_open_files(db_options, 1024);
        // 写入阶段采取只写模式，不使用操作系统缓冲区。这是因为compaction触发晚，因此缓存意义较小，减少内存拷贝。
        // 在windows测试时，发现有文件删除延迟导致磁盘耗尽的现象，不确定`direct_io`是否有影响。
        c.rocksdb_options_set_use_direct_io_for_flush_and_compaction(db_options, 1);
        if (ctx.compression) {
            // 关于压缩：原则上compaction阶段的压缩才影响最终大小，而写入阶段的压缩只影响中间文件大小而不影响最终大小。
            // 但是，在对postgresql的测试中，如果compaction阶段都不压缩，而只检验写入阶段的压缩，发现写入阶段压缩比不压缩反而快30秒左右（13分50秒与14分36秒的区别）
            // 这说明中间文件的大小变小实际上由于降低了I/O量，导致中间过程的压缩也反而对性能有益而非有害。
            c.rocksdb_options_set_compression(db_options, c.rocksdb_lz4_compression);
        }
        // 发现文件删除延迟导致磁盘耗尽现象。虽然我看文档说compaction会自动删除，不受此配置影响，但是观测的删除依然延迟。增加每分钟一次的删除废弃文件。
        // 增加以后仍然未解决。后得知应该是删除线程的异步性导致被compaction的文件未能被及时删除，因为删除的线程应该始终未能被执行。
        // 而flush线程才是被优先执行的。
        c.rocksdb_options_set_delete_obsolete_files_period_micros(db_options, 30 * 1000000);
        // 为此，增加SstFileManager检测磁盘限制。
        // 仍有争议，暂不实现。

        // 此配置为关键混合配置：部分影响数据库行为，部分影响默认列族的行为。
        // FAQ说这个函数会使用vector memtable。如果是这样的话，对我这种乱序写入的场景就不适合了。
        // 但是，所幸的是，看了[源码](https://github.com/facebook/rocksdb/blob/a34683bf543cc3eb151d08eeac00791862acd4d6/options/options.cc#L478-L519)
        // 实际没有修改memtable使用类型的行为，仅仅是全部写入L0以及禁止自动压缩。这些行为都是我需要的，可以放心使用。
        // 这个行为会设置`flush`线程为4。不用担心`flush`线程数影响parser等其他线程，因为这是I/O密集线程，不怎么影响计算线程。
        // 补：最终发现如果不compaction，会导致写入量过大，如果磁盘不是非常大的话，会导致磁盘耗尽。
        // 因此除非设置的compaction-trigger为0，否则依然采用自动compaction，但是相关配置会仿照parepare_for_bulk_load进行一些修改以减少写放大。
        if (ctx.compaction_trigger == 0) {
            c.rocksdb_options_prepare_for_bulk_load(db_options);
            // 进一步增加`flush`线程数，因为发现瓶颈可能在flush
            c.rocksdb_options_set_max_background_flushes(db_options, @intCast(ctx.n_rocksdbjobs));
        } else {
            c.rocksdb_options_set_level0_file_num_compaction_trigger(db_options, ctx.compaction_trigger);
            // NOTE：减缓和停止触发器设置为极大值，具体减缓和停止的触发会基于`soft_pending_compaction_bytes_limit`和`hard_pending_compaction_bytes_limit`
            // 这两个参数默认为64GB和256GB，符合需求。——本来我是这么想的。
            // 但是最终还是磁盘空间耗尽，导致我最终尝试设置写入减缓和停止的触发。目前采取compaction_trigger的两倍和4倍。
            c.rocksdb_options_set_level0_slowdown_writes_trigger(db_options, ctx.compaction_trigger * 2);
            c.rocksdb_options_set_level0_stop_writes_trigger(db_options, ctx.compaction_trigger * 4);
            // 以下配置来自prepare for bulk load内部实现。
            c.rocksdb_options_set_max_compaction_bytes(db_options, 1 << 60);
            c.rocksdb_options_set_num_levels(db_options, 2);
            c.rocksdb_options_set_max_write_buffer_number(db_options, 6);
            c.rocksdb_options_set_min_write_buffer_number_to_merge(db_options, 1);
            c.rocksdb_options_set_target_file_size_base(db_options, 256 * 1024 * 1024);
            // flush和compaction的线程分配交给前面的`rocksdb_options_increase_parallelism`自动进行。
        }

        // 以下为默认列族相关配置
        // 增加`write_buffer_size`。目前默认的64MB可能导致多个小sst文件，增大单个sst文件的大小，降低文件数量，以避免文件打开与关闭开销。
        // 只设置默认列族就够了，其他列族用不着。
        c.rocksdb_options_set_write_buffer_size(db_options, 256 * 1024 * 1024);
        c.rocksdb_options_set_max_write_buffer_number(db_options, @intCast(ctx.n_rocksdbjobs));
        // 一定要小心，此处神坑！这两个东西进入options时都会变成`shared ptr`并且移交所有权！
        // 千万不要调用C API提供的`rocksdb_slicetransform_destroy`和`rocksdb_mergeoperator_destroy`！
        // 默认列族以path-id为前缀。不使用布隆过滤器，因为后续使用数据库的时候基本没有需要检查无效的key的情况。
        c.rocksdb_options_set_prefix_extractor(db_options, c.rocksdb_slicetransform_create_fixed_prefix(@sizeOf(BlobPathSeq)));
        // c.rocksdb_options_set_merge_operator(db_options, ctx.writer.merge_operator_state.createCommitRangesMergeOperater());
        // 注：当options已经被用于打开rocksdb以后，rocksdb内部有此配置的拷贝，对options的直接修改不会影响rocksdb。
        // 虽然后续可以用`rocksdb_set_options`和`rocksdb_set_options_cf`中途修改各默认列族的行为。
        // 但是，C API不支持`SetDBOptions`，也就是修改数据库本体的操作。后续必须关闭数据库再重新打开。
        break :blk db_options.?;
    };
    defer c.rocksdb_options_destroy(db_options);

    const db = blk: {
        const db = c.rocksdb_open(db_options, ctx.rocksdb_output.get(), @ptrCast(&err_cstr));
        if (err_cstr) |ecstr| {
            std.log.err("rocksdb create failed! {s}\n", .{std.mem.span(ecstr)});
            gvca.crash_dump.dumpAndCrash(@src());
        }
        break :blk db.?;
    };
    defer c.rocksdb_close(db);

    // 默认列族：键是blob_path_index-commit_index的二元组，值为空。
    const cf_bpi_ci = c.rocksdb_get_default_column_family_handle(db).?;
    defer c.rocksdb_column_family_handle_destroy(cf_bpi_ci);

    const woptions = blk: {
        const woptions = c.rocksdb_writeoptions_create();
        c.rocksdb_writeoptions_disable_WAL(woptions, 1);
        break :blk woptions.?;
    };
    defer c.rocksdb_writeoptions_destroy(woptions);

    const wb = c.rocksdb_writebatch_create().?;
    defer c.rocksdb_writebatch_destroy(wb);

    var consumer_local = ctx.channel.mpsc_queue_ref.initConsumerLocal();

    // XXX: 如果阻塞，添加一些异步执行的内容。但目前没什么想法。
    while (ctx.channel.claimConsume(&consumer_local, null)) |lease| {
        const ticket, const parsed: *PrepRunner.Parsed = lease;
        // mpsc队列中消费者不比生产者，生产者写入过程需要尽可能快否则消费者可能卡在慢生产者后面。消费者慢点卡着没逝的。
        defer ctx.channel.releaseConsumedUnsafe(ticket);
        // XXX: 跨任务的`writebatch`堆积。目前的默认列族写入三元组不涉及动态内存，考虑实现。

        // 设置`key`
        for (parsed.parsed_units.items, keys_buf_cursor..) |*parsed_unit, i| {
            const path_get_or_put_result = ctx.writer.path_registry.map.getOrPut(ctx.writer.path_registry.arena.allocator(), parsed_unit.path) catch |err| {
                diagnostics.log_all(err);
                diagnostics.clear();
                gvca.crash_dump.dumpAndCrash(@src());
            };
            if (!path_get_or_put_result.found_existing) {
                // 注意！`getOrPut`会直接把我们用于比较的`parsed_unit.path`作为键。但是`parsed_unit.path`的生存周期实际上并不够！
                // 因此，我们需要重新设置一个生命周期安全的新key，也就是将当前的`parsed_unit.path`用hash map自己的分配器重新拷贝一份。
                // 虽然文档让我们不要修改键，但我想我知道我们现在在做什么。
                path_get_or_put_result.key_ptr.* = std.mem.Allocator.dupe(ctx.writer.path_registry.arena.allocator(), u8, parsed_unit.path) catch |err| {
                    diagnostics.log_all(err);
                    diagnostics.clear();
                    gvca.crash_dump.dumpAndCrash(@src());
                };
                path_get_or_put_result.value_ptr.* = .{
                    .index = .fromNative(@intCast(path_get_or_put_result.index)),
                    .blob_cnt = 0, // 接下来很快会因为`blob_path_registry不命中而增加至1。
                };
            }
            const blob_path_key: BlobPathKey = .{
                .blob_hash = parsed_unit.blob_hash,
                .path_seq = path_get_or_put_result.value_ptr.index,
            };
            const blob_path_get_or_put_result = ctx.writer.blob_path_registry.map.getOrPut(ctx.writer.blob_path_registry.arena.allocator(), blob_path_key) catch |err| {
                diagnostics.log_all(err);
                diagnostics.clear();
                gvca.crash_dump.dumpAndCrash(@src());
            };
            if (!blob_path_get_or_put_result.found_existing) {
                // 如果不存在，map的count会立刻加1。我们实际的index从0开始算，所以index是count - 1。
                blob_path_get_or_put_result.value_ptr.* = .fromNative(ctx.writer.blob_path_registry.map.count() - 1);
                // 如果这是一个新的path-blob组合，path的blob_cnt立即加1。
                path_get_or_put_result.value_ptr.blob_cnt += 1;
            }
            keys_buf[i] = .{
                .blob_path_seq = blob_path_get_or_put_result.value_ptr.*,
                .commit_seq = parsed.commit_seq,
            };
            c.rocksdb_writebatch_put_cf(
                wb,
                cf_bpi_ci,
                @ptrCast(&keys_buf[i]),
                @sizeOf(Key),
                null,
                0,
            );
        }
        // std.log.debug("putv {d} keys at cursor {d}", .{ parsed.parsed_units.items.len, keys_buf_cursor });
        if (c.rocksdb_writebatch_count(wb) > write_batch_threshold) {
            c.rocksdb_write(db, woptions, wb, @ptrCast(&err_cstr));
            if (err_cstr) |ecstr| {
                std.log.err("rocksdb write failed! {s}\n", .{std.mem.span(ecstr)});
                gvca.crash_dump.dumpAndCrash(@src());
            }
            c.rocksdb_writebatch_clear(wb);
        }
        keys_buf_cursor = @intCast(c.rocksdb_writebatch_count(wb));
        // std.log.debug("cursor move to {d}", .{keys_buf_cursor});
        // 销毁一切。
        parsed.arena.deinit();
    } else |_| {
        c.rocksdb_write(db, woptions, wb, @ptrCast(&err_cstr));
        if (err_cstr) |ecstr| {
            std.log.err("rocksdb write failed! {s}\n", .{std.mem.span(ecstr)});
            gvca.crash_dump.dumpAndCrash(@src());
        }
        c.rocksdb_writebatch_clear(wb);
        std.log.debug("Parse end.\n", .{});
    }

    // 为其它列族设置单独的默认配置（它们不需要前缀提取器和merge operator）
    // 尽管可能的写入方式仍然存在一些区别，简单考虑依旧使用相同的配置。
    const cf_options = blk: {
        const cf_options = c.rocksdb_options_create();
        c.rocksdb_options_prepare_for_bulk_load(cf_options);
        if (ctx.compression) {
            c.rocksdb_options_set_compression(cf_options, c.rocksdb_lz4_compression);
        }
        break :blk cf_options.?;
    };
    defer c.rocksdb_options_destroy(cf_options);

    // 其他列族写入：基于各个hash map一次性写入所有内容。
    // 键 commit_index - 值 commit 列族
    const cf_ci_c = blk: {
        const cf_ci_c = c.rocksdb_create_column_family(db, cf_options, "ci2c", @ptrCast(&err_cstr));
        if (err_cstr) |ecstr| {
            std.log.err("rocksdb create column family 'ci2c' failed! {s}\n", .{std.mem.span(ecstr)});
            gvca.crash_dump.dumpAndCrash(@src());
        }
        break :blk cf_ci_c.?;
    };
    defer c.rocksdb_column_family_handle_destroy(cf_ci_c);
    // 从commit registry写入ci2c列族。目前使用的是hash map，难以保证顺序。故乱序写入。
    write_ci2c: {
        var iter = ctx.commit_registry.map.iterator();
        while (iter.next()) |entry| {
            c.rocksdb_writebatch_put_cf(
                wb,
                cf_ci_c,
                @ptrCast(entry.value_ptr),
                @sizeOf(CommitSeq),
                @ptrCast(&entry.key_ptr.id),
                @sizeOf(@TypeOf(entry.key_ptr.id)),
            );
            if (c.rocksdb_writebatch_count(wb) > write_batch_threshold) {
                c.rocksdb_write(db, woptions, wb, @ptrCast(&err_cstr));
                if (err_cstr) |ecstr| {
                    std.log.err("rocksdb write ci2c failed! {s}\n", .{std.mem.span(ecstr)});
                    gvca.crash_dump.dumpAndCrash(@src());
                }
                c.rocksdb_writebatch_clear(wb);
            }
        }
        c.rocksdb_write(db, woptions, wb, @ptrCast(&err_cstr));
        if (err_cstr) |ecstr| {
            std.log.err("rocksdb write ci2c failed! {s}\n", .{std.mem.span(ecstr)});
            gvca.crash_dump.dumpAndCrash(@src());
        }
        c.rocksdb_writebatch_clear(wb);
        break :write_ci2c;
    }
    // 键 path_index - 值 path 列族
    // XXX: 由于用的是array hash map，有序，理论上可以用sst文件直接写入。
    const cf_pi_p = blk: {
        const cf_pi_p = c.rocksdb_create_column_family(db, cf_options, "pi2p", @ptrCast(&err_cstr));
        if (err_cstr) |ecstr| {
            std.log.err("rocksdb create column family 'pi2p' failed! {s}\n", .{std.mem.span(ecstr)});
            gvca.crash_dump.dumpAndCrash(@src());
        }
        break :blk cf_pi_p.?;
    };
    defer c.rocksdb_column_family_handle_destroy(cf_pi_p);
    write_pi2p: {
        var iter = ctx.writer.path_registry.map.iterator();
        while (iter.next()) |entry| {
            c.rocksdb_writebatch_put_cf(
                wb,
                cf_pi_p,
                @ptrCast(&entry.value_ptr.index),
                @sizeOf(PathSeq),
                @ptrCast(entry.key_ptr.ptr),
                entry.key_ptr.len,
            );
            if (c.rocksdb_writebatch_count(wb) > write_batch_threshold) {
                c.rocksdb_write(db, woptions, wb, @ptrCast(&err_cstr));
                if (err_cstr) |ecstr| {
                    std.log.err("rocksdb write pi2p failed! {s}\n", .{std.mem.span(ecstr)});
                    gvca.crash_dump.dumpAndCrash(@src());
                }
                c.rocksdb_writebatch_clear(wb);
            }
        }
        c.rocksdb_write(db, woptions, wb, @ptrCast(&err_cstr));
        if (err_cstr) |ecstr| {
            std.log.err("rocksdb write pi2p failed! {s}\n", .{std.mem.span(ecstr)});
            gvca.crash_dump.dumpAndCrash(@src());
        }
        c.rocksdb_writebatch_clear(wb);
        break :write_pi2p;
    }
    // 键 path_index-blob - 值 blob_path_index 列族
    const cf_b_pi_bpi = blk: {
        const cf_b_pi_bpi = c.rocksdb_create_column_family(db, cf_options, "b_pi2bpi", @ptrCast(&err_cstr));
        if (err_cstr) |ecstr| {
            std.log.err("rocksdb create column family 'b_pi2bpi' failed! {s}\n", .{std.mem.span(ecstr)});
            gvca.crash_dump.dumpAndCrash(@src());
        }
        break :blk cf_b_pi_bpi.?;
    };
    defer c.rocksdb_column_family_handle_destroy(cf_b_pi_bpi);
    write_b_pi2bpi: {
        var iter = ctx.writer.blob_path_registry.map.iterator();
        while (iter.next()) |entry| {
            c.rocksdb_writebatch_put_cf(
                wb,
                cf_b_pi_bpi,
                @ptrCast(entry.key_ptr),
                @sizeOf(BlobPathKey),
                @ptrCast(entry.value_ptr),
                @sizeOf(BlobPathSeq),
            );
            if (c.rocksdb_writebatch_count(wb) > write_batch_threshold) {
                c.rocksdb_write(db, woptions, wb, @ptrCast(&err_cstr));
                if (err_cstr) |ecstr| {
                    std.log.err("rocksdb write b_pi2bpi failed! {s}\n", .{std.mem.span(ecstr)});
                    gvca.crash_dump.dumpAndCrash(@src());
                }
                c.rocksdb_writebatch_clear(wb);
            }
        }
        c.rocksdb_write(db, woptions, wb, @ptrCast(&err_cstr));
        if (err_cstr) |ecstr| {
            std.log.err("rocksdb write b_pi2bpi failed! {s}\n", .{std.mem.span(ecstr)});
            gvca.crash_dump.dumpAndCrash(@src());
        }
        c.rocksdb_writebatch_clear(wb);
        break :write_b_pi2bpi;
    }

    // 后处理：修改配置不再启用 prepare for bulk load
    // 先确保可能写入的列族全部刷新到磁盘。
    const foptions = c.rocksdb_flushoptions_create().?;
    defer c.rocksdb_flushoptions_destroy(foptions);
    c.rocksdb_flushoptions_set_wait(foptions, 1);
    flush_all: {
        var column_family = [_]?*c.struct_rocksdb_column_family_handle_t{
            cf_bpi_ci,
            cf_pi_p,
            cf_ci_c,
        };
        c.rocksdb_flush_cfs(db, foptions, &column_family, column_family.len, @ptrCast(&err_cstr));
        if (err_cstr) |ecstr| {
            std.log.err("rocksdb flush failed! {s}\n", .{std.mem.span(ecstr)});
            gvca.crash_dump.dumpAndCrash(@src());
        }
        break :flush_all;
    }
    std.log.debug("Write end. All flushed\n", .{});
}
