const std = @import("std");
const gvca = @import("gvca");
const diag = gvca.diag;
const PrepRunner = @import("PrepRunner.zig");
const c = gvca.c_helper.c;
const PathSeq = PrepRunner.PathSeq;
const PathBlobSeq = PrepRunner.PathBlobSeq;

// write线程执行完的后续。
pub fn compaction(ctx: *PrepRunner, allocator: std.mem.Allocator, last_diag: *diag.Diagnostic) !void {
    _ = last_diag;
    // 由于C API没有对`SetDbOptions`的支持，因此只得关闭数据库后，根据修改后的配置重新打开。
    var err_cstr: ?[*:0]u8 = null;
    const lru_cache = c.rocksdb_cache_create_lru(256 * 1024 * 1024).?;
    defer c.rocksdb_cache_destroy(lru_cache);
    const table_options = blk: {
        const table_options = c.rocksdb_block_based_options_create();
        c.rocksdb_block_based_options_set_block_cache(table_options, lru_cache);
        break :blk table_options.?;
    };
    defer c.rocksdb_block_based_options_destroy(table_options);
    // 依然让数据库与主列族共用一个options
    const db_options = blk: {
        const db_options = c.rocksdb_options_create();
        c.rocksdb_options_set_create_if_missing(db_options, 0);
        c.rocksdb_options_set_error_if_exists(db_options, 0);
        c.rocksdb_options_increase_parallelism(db_options, @intCast(ctx.n_rocksdbjobs));
        c.rocksdb_options_set_max_background_compactions(db_options, @intCast(ctx.n_rocksdbjobs));
        c.rocksdb_options_set_max_background_flushes(db_options, 1);
        // 依旧禁用自动compaction。我们使用手动compaction，避免撞车。
        c.rocksdb_options_set_disable_auto_compactions(db_options, 1);
        c.rocksdb_options_set_max_open_files(db_options, 1024);
        // 手动compaction的最大字节数应为极大值。
        c.rocksdb_options_set_max_compaction_bytes(db_options, 1 << 60);
        // 下面为默认列族配置
        c.rocksdb_options_set_prefix_extractor(db_options, c.rocksdb_slicetransform_create_fixed_prefix(@sizeOf(PathBlobSeq)));
        // c.rocksdb_options_set_merge_operator(db_options, ctx.writer.merge_operator_state.createCommitRangesMergeOperater());
        // 在compaction阶段，增加block cache量。默认32Mb，我们增加到256Mb。
        // 实际命中率不高，不用特别注意。
        c.rocksdb_options_set_block_based_table_factory(db_options, table_options);
        // compaction时仍然创建新的sst文件，因此如果需要压缩，仍要配置。
        if (ctx.compression) {
            c.rocksdb_options_set_compression(db_options, c.rocksdb_lz4_compression);
        }
        break :blk db_options.?;
    };
    defer c.rocksdb_options_destroy(db_options);

    // 其它列族的选项
    const cf_options = blk: {
        const cf_options = c.rocksdb_options_create();
        if (ctx.compression) {
            c.rocksdb_options_set_compression(cf_options, c.rocksdb_lz4_compression);
        }
        break :blk cf_options.?;
    };
    defer c.rocksdb_options_destroy(cf_options);

    const db, const cf_pbi_ci, const cf_pi_p, const cf_pi_b_pbi, const cf_ci_c = reopen_db: {
        const column_family_names = [_][*:0]const u8{
            "default",
            "pi2p",
            "pib2pbi",
            "ci2c",
        };
        const column_family_options: [column_family_names.len]?*const c.rocksdb_options_t = .{
            db_options,
            cf_options,
            cf_options,
            cf_options,
        };
        var column_family_handles: [column_family_names.len]?*c.rocksdb_column_family_handle_t = undefined;
        // 其他列族已经不再需要，但是打开的时候必须打开所有列族，否则就报失败。
        const new_db = c.rocksdb_open_column_families(
            db_options,
            ctx.rocksdb_output.get(),
            column_family_names.len,
            @ptrCast(&column_family_names),
            &column_family_options,
            &column_family_handles,
            @ptrCast(&err_cstr),
        );
        if (err_cstr) |ecstr| {
            std.log.err("rocksdb reopen failed! {s}\n", .{std.mem.span(ecstr)});
            return error.RocksdbError;
        }
        break :reopen_db .{ new_db.?, column_family_handles[0].?, column_family_handles[1].?, column_family_handles[2].?, column_family_handles[3].? };
    };
    defer {
        c.rocksdb_column_family_handle_destroy(cf_pbi_ci);
        c.rocksdb_column_family_handle_destroy(cf_pi_p);
        c.rocksdb_column_family_handle_destroy(cf_pi_b_pbi);
        c.rocksdb_column_family_handle_destroy(cf_ci_c);
        c.rocksdb_close(db);
    }
    // 触发手动compaction（整个数据库）
    std.log.info("Compaction start.\n", .{});
    const compact_options = c.rocksdb_compactoptions_create();
    defer c.rocksdb_compactoptions_destroy(compact_options);

    c.rocksdb_compact_range_opt(db, compact_options, null, 0, null, 0);
    // 等待compaction完成
    // XXX: 如果不必重新打开数据库的话，此处可以配置压缩前刷写数据库，或许可以不再需要前面手动flush。不过现在说这个有些晚了。
    const wait_for_compact_options = c.rocksdb_wait_for_compact_options_create().?;
    defer c.rocksdb_wait_for_compact_options_destroy(wait_for_compact_options);

    c.rocksdb_wait_for_compact(db, wait_for_compact_options, @ptrCast(&err_cstr));
    if (err_cstr) |ecstr| {
        std.log.err("rocksdb wait for compact failed! {s}\n", .{std.mem.span(ecstr)});
        return error.RocksdbError;
    }

    // 另一种方案等待 Compaction 完成，为了保险起见，因为不熟悉`rocksdb_wait_for_compact`
    while (true) {
        var num_running: u64 = undefined;
        var err = c.rocksdb_property_int(db, "rocksdb.num-running-compactions", &num_running);
        if (err != 0) {
            std.log.err("rocksdb write failed! {d}\n", .{err});
            return error.RocksdbError;
        }

        var pending: u64 = undefined;
        err = c.rocksdb_property_int(db, "rocksdb.compaction-pending", &pending);
        if (err != 0) {
            std.log.err("rocksdb write failed! {d}\n", .{err});
            return error.RocksdbError;
        }

        if (num_running == 0 and pending == 0) {
            std.debug.print("Compaction completed.\n", .{});
            break;
        }
        std.debug.print("Waiting for compaction: running={d}, pending={d}\n", .{ num_running, pending });
        std.Thread.sleep(10 * std.time.ns_per_s); // 等待 10s
    }

    // 开始cf_pr_pi写入
    // 对blob_cnt进行排序
    sort: {
        const SortContext = struct {
            map: *const @TypeOf(ctx.writer.path_registry.map),
            pub fn lessThan(sctx: @This(), a_index: usize, b_index: usize) bool {
                // 基于值中的 blob_cnt 比较。采用降序，符号翻转。
                return sctx.map.values()[a_index].blob_cnt > sctx.map.values()[b_index].blob_cnt;
            }
        };
        const sctx: SortContext = .{ .map = &ctx.writer.path_registry.map };
        ctx.writer.path_registry.map.sort(sctx);
        break :sort;
    }
    // 写入sst文件。此过程相对独立。写入一个临时文件。
    const cf_pr_pi_options = blk: {
        const cf_pr_pi_options = c.rocksdb_options_create();
        // 将写入的SST文件导入列族。仅需要设置列族级别即可。
        // 因为数据库级别的`prepare_for_bulk_load`影响的是`max_background_flushes`和`max_background_compactions`
        // 其中前者无意义，后者建议禁用最后手动compaction
        c.rocksdb_options_prepare_for_bulk_load(cf_pr_pi_options);
        break :blk cf_pr_pi_options.?;
    };
    defer c.rocksdb_options_destroy(cf_pr_pi_options);
    // 基于临时文件名前缀确定写入的临时sst文件名。
    const sst_file_name: [:0]u8 = blk: {
        var sst_file_name_writer: std.Io.Writer.Allocating = .init(allocator);
        try sst_file_name_writer.writer.print("{s}/{d}-{d}-pr2pi-sst", .{
            std.fs.path.dirname(ctx.rocksdb_output.get()) orelse ".",
            ctx.proc_stamp.pid,
            ctx.proc_stamp.ts,
        });
        break :blk try sst_file_name_writer.toOwnedSliceSentinel(0);
    };
    defer allocator.free(sst_file_name);
    sst_file_write: {
        const env = c.rocksdb_envoptions_create().?;
        defer c.rocksdb_envoptions_destroy(env);
        const sstwriter = c.rocksdb_sstfilewriter_create(env, cf_pr_pi_options);
        defer c.rocksdb_sstfilewriter_destroy(sstwriter);
        c.rocksdb_sstfilewriter_open(sstwriter, sst_file_name.ptr, @ptrCast(&err_cstr));
        if (err_cstr) |ecstr| {
            std.log.err("rocksdb sstfilewriter open failed! {s}\n", .{std.mem.span(ecstr)});
            return error.RocksdbError;
        }
        defer {
            c.rocksdb_sstfilewriter_finish(sstwriter, @ptrCast(&err_cstr));
            if (err_cstr) |ecstr| {
                std.log.err("rocksdb sstfilewriter finish failed! {s}\n", .{std.mem.span(ecstr)});
                gvca.crash_dump.dumpAndCrash(@src());
            }
        }

        // 遍历排序后的`path_registry`，写入sst
        var iter = ctx.writer.path_registry.map.iterator();
        var key: usize = undefined;
        while (do: {
            key = std.mem.nativeToBig(usize, iter.index);
            break :do iter.next();
        }) |entry| {
            // sstfilewriter与writebatch不同，每次put以后，key和value的生存期即可结束，不需要长期维持生存期
            c.rocksdb_sstfilewriter_put(sstwriter, @ptrCast(&key), @sizeOf(usize), @ptrCast(&entry.value_ptr.index), @sizeOf(PathSeq), @ptrCast(&err_cstr));
            if (err_cstr) |ecstr| {
                std.log.err("rocksdb sstfilewriter put failed! {s}\n", .{std.mem.span(ecstr)});
                return error.RocksdbError;
            }
        }
        break :sst_file_write;
    }

    // 键 path_rank - 值 path_index 列族。
    // 这个列族的键需要在全部写入完毕以后重新遍历获取，仅适合在最后单独写入。
    const cf_pr_pi = blk: {
        const cf_pr_pi = c.rocksdb_create_column_family(db, cf_options, "pr2pi", @ptrCast(&err_cstr));
        if (err_cstr) |ecstr| {
            std.log.err("rocksdb create column family 'ci2c' failed! {s}\n", .{std.mem.span(ecstr)});
            return error.RocksdbError;
        }
        break :blk cf_pr_pi.?;
    };
    defer c.rocksdb_column_family_handle_destroy(cf_pr_pi);

    // 将sst文件导入列族
    const ifo = blk: {
        const ifo = c.rocksdb_ingestexternalfileoptions_create();
        // 虽然设置了全局序列号，但是仍然警告`At least one SST file opened without unique ID to verify`且`global_seqno=0`
        // 有人说可能与`prepare_for_bulk_load`有关。
        // [参见](https://forums.percona.com/t/rocksdb-alter-table-fails-silently-and-drops-all-data-global-seqno-is-required-but-disabled/27038)
        c.rocksdb_ingestexternalfileoptions_set_allow_global_seqno(ifo, 1);
        c.rocksdb_ingestexternalfileoptions_set_move_files(ifo, 1);
        break :blk ifo.?;
    };
    defer c.rocksdb_ingestexternalfileoptions_destroy(ifo);
    const file_list = [_][*:0]const u8{
        sst_file_name,
    };
    c.rocksdb_ingest_external_file_cf(db, cf_pr_pi, @ptrCast(&file_list), file_list.len, ifo, @ptrCast(&err_cstr));
    if (err_cstr) |ecstr| {
        std.log.err("rocksdb ingest external file failed! {s}\n", .{std.mem.span(ecstr)});
        return error.RocksdbError;
    }
    // 再次触发compaction（复用先前的compaction配置）
    c.rocksdb_compact_range_cf_opt(db, cf_pr_pi, compact_options, null, 0, null, 0);
    c.rocksdb_wait_for_compact(db, wait_for_compact_options, @ptrCast(&err_cstr));
    if (err_cstr) |ecstr| {
        std.log.err("rocksdb wait for compact failed! {s}\n", .{std.mem.span(ecstr)});
        return error.RocksdbError;
    }
    // 导入完毕以后，删除临时的sstfile文件。
    // 不再需要，因为导入配置为了move files
    // try std.fs.cwd().deleteFile(sst_file_name);
}
