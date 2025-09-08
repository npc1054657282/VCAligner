const std = @import("std");
const gvca = @import("gvca");
const diag = gvca.diag;
const PrepRunner = @import("PrepRunner.zig");
const c = gvca.c_helper.c;
const PathSeq = PrepRunner.PathSeq;

// write线程执行完的后续。
pub fn compaction(ctx: *PrepRunner, allocator: std.mem.Allocator, last_diag: *diag.Diagnostic) !void {
    _ = allocator;
    _ = last_diag;
    // 由于C API没有对`SetDbOptions`的支持，因此只得关闭数据库后，根据修改后的配置重新打开。
    var err_cstr: ?[*:0]u8 = null;
    // 依然让数据库与主列族共用一个options
    const db_options = blk: {
        const db_options = c.rocksdb_options_create();
        c.rocksdb_options_set_create_if_missing(db_options, 0);
        c.rocksdb_options_set_error_if_exists(db_options, 0);
        c.rocksdb_options_increase_parallelism(db_options, @intCast(ctx.n_jobs));
        c.rocksdb_options_set_max_background_compactions(db_options, @intCast(ctx.n_jobs));
        c.rocksdb_options_set_max_background_flushes(db_options, 1);
        // 下面为默认列族配置
        c.rocksdb_options_set_prefix_extractor(db_options, c.rocksdb_slicetransform_create_fixed_prefix(@sizeOf(PathSeq)));
        c.rocksdb_options_set_merge_operator(db_options, ctx.writer.merge_operator_state.createFixedBinaryAppendMergeOperater());
        break :blk db_options.?;
    };
    defer c.rocksdb_options_destroy(db_options);

    // 其它列族的选项
    const cf_options = c.rocksdb_options_create().?;
    defer c.rocksdb_options_destroy(cf_options);

    const db, const cf_pi_b_cis, const cf_pi_p, const cf_ci_c = reopen_db: {
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
            return error.RocksdbError;
        }
        break :reopen_db .{ new_db.?, column_family_handles[0].?, column_family_handles[1].?, column_family_handles[2].? };
    };
    defer {
        c.rocksdb_column_family_handle_destroy(cf_pi_b_cis);
        c.rocksdb_column_family_handle_destroy(cf_pi_p);
        c.rocksdb_column_family_handle_destroy(cf_ci_c);
        c.rocksdb_close(db);
    }
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
    defer {
        std.log.info("pr2pi handle destroy...\n", .{});
        c.rocksdb_column_family_handle_destroy(cf_pr_pi);
    }
    std.log.info("Create pr2pi OK.\n", .{});
}
