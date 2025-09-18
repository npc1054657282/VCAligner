const std = @import("std");
const gvca = @import("gvca");
const c = gvca.c_helper.c;
const AnaRunner = @import("AnaRunner.zig");
const diag = gvca.diag;
const PathSeq = gvca.rocksdb_custom.PathSeq;
const PathBlobSeq = gvca.rocksdb_custom.PathBlobSeq;

pub fn analysis(ctx: *AnaRunner, allocator: std.mem.Allocator, last_diag: *diag.Diagnostic) !void {
    _ = allocator;
    _ = last_diag;
    var err_cstr: ?[*:0]u8 = null;
    const db_options = blk: {
        const db_options = c.rocksdb_options_create();
        c.rocksdb_options_optimize_for_point_lookup(db_options, ctx.point_lookup_cache_mb);
        // 以下为默认列族设置
        c.rocksdb_options_set_prefix_extractor(db_options, c.rocksdb_slicetransform_create_fixed_prefix(@sizeOf(PathBlobSeq)));
        break :blk db_options.?;
    };
    defer c.rocksdb_options_destroy(db_options);
    const cf_options = c.rocksdb_options_create().?;
    defer c.rocksdb_options_destroy(cf_options);
    const db, const cf_pbi_ci, const cf_pi_p, const cf_pi_b_pbi, const cf_ci_c, const cf_pr_pi = open_db: {
        const column_family_names = [_][*:0]const u8{
            "default",
            "pi2p",
            "pib2pbi",
            "ci2c",
            "pr2pi",
        };
        const column_family_options: [column_family_names.len]?*const c.rocksdb_options_t = .{
            db_options,
            cf_options,
            cf_options,
            cf_options,
            cf_options,
        };
        var column_family_handles: [column_family_names.len]?*c.rocksdb_column_family_handle_t = undefined;
        const new_db = c.rocksdb_open_for_read_only_column_families(
            db_options,
            ctx.rocksdb_path,
            column_family_names.len,
            @ptrCast(&column_family_names),
            &column_family_options,
            &column_family_handles,
            1,
            @ptrCast(&err_cstr),
        );
        if (err_cstr) |ecstr| {
            std.log.err("rocksdb open failed! {s}\n", .{std.mem.span(ecstr)});
            return error.RocksdbError;
        }
        break :open_db .{
            new_db.?,
            column_family_handles[0].?,
            column_family_handles[1].?,
            column_family_handles[2].?,
            column_family_handles[3].?,
            column_family_handles[4].?,
        };
    };
    defer {
        c.rocksdb_column_family_handle_destroy(cf_pbi_ci);
        c.rocksdb_column_family_handle_destroy(cf_pi_p);
        c.rocksdb_column_family_handle_destroy(cf_pi_b_pbi);
        c.rocksdb_column_family_handle_destroy(cf_ci_c);
        c.rocksdb_column_family_handle_destroy(cf_pr_pi);
        c.rocksdb_close(db);
    }
}

// 第一步：读取pr2pi列族和pi2p列族，获得一个path和pi的有序列表。
// 第二步：遍历该列表，下发子任务：
// 二·一找release_path中是否存在对应路径。
// 二·二：找到对应路径的文件，若存在，将release_path下的对应文件进行hash。
// 二·三，根据hash结果，通过pib2pbi寻找是否存在对应的blob id。
// 二·四：读取default，根据path-blob对前缀匹配，获得所有键，归并为一个commit id range 列表。
// 第三步：所有子任务执行完成以后，我们得到的是一个commit id range列表的[序列]。现在我们再设置一类commit id range列表的output[集合]。
// 遍历[序列]，不断将序列的当前commit id range列表与[集合]里的所有commit id range列表取交集。交集为空认为失败。
// 如果全部没有交集，当前的commit id range列表成为[集合]的一个新成员。显然，所有集合都是互不相交的。
