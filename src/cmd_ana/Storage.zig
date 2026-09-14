const vcaligner = @import("vcaligner");
const c_helper = vcaligner.c_helper;
const c = c_helper.c;
const std = @import("std");

const Storage = @This();

db: *c.rocksdb_t,
cfs: vcaligner.rocksdb_custom.CollumFamily.Handles,

pub fn init(
    point_lookup_cache_mb: u64,
    rocksdb_path: [:0]const u8,
    last_diag: *vcaligner.diag.Diagnostic,
) !Storage {
    const db_options = blk: {
        const db_options = c.rocksdb_options_create();
        c.rocksdb_options_optimize_for_point_lookup(db_options, point_lookup_cache_mb);
        break :blk db_options.?;
    };
    defer c.rocksdb_options_destroy(db_options);
    const normal_cf_options = c.rocksdb_options_create().?;
    defer c.rocksdb_options_destroy(normal_cf_options);
    var all_cf_options: std.enums.EnumArray(vcaligner.rocksdb_custom.CollumFamily, ?*c.rocksdb_options_t) = .init(.{
        .bpi_ci = undefined,
        .pi2p = normal_cf_options,
        .b_pi2bpi = undefined,
        .ci2c = normal_cf_options,
        .pr_bc2pi = normal_cf_options,
    });
    all_cf_options.set(.bpi_ci, blk: {
        const cf_options = c.rocksdb_options_create().?;
        c.rocksdb_options_set_prefix_extractor(cf_options, c.rocksdb_slicetransform_create_fixed_prefix(@sizeOf(vcaligner.rocksdb_custom.BlobPathSeq)));
        break :blk cf_options;
    });
    defer c.rocksdb_options_destroy(all_cf_options.get(.bpi_ci));
    all_cf_options.set(.b_pi2bpi, blk: {
        const cf_options = c.rocksdb_options_create().?;
        c.rocksdb_options_set_prefix_extractor(cf_options, c.rocksdb_slicetransform_create_fixed_prefix(@sizeOf(c.git_oid)));
        break :blk cf_options;
    });
    defer c.rocksdb_options_destroy(all_cf_options.get(.b_pi2bpi));
    var cfs: vcaligner.rocksdb_custom.CollumFamily.Handles = undefined;
    var err_cstr: ?[*:0]u8 = null;
    const db = c.rocksdb_open_for_read_only_column_families(
        db_options,
        rocksdb_path,
        vcaligner.rocksdb_custom.CollumFamily.names.values.len,
        @ptrCast(&vcaligner.rocksdb_custom.CollumFamily.names.values),
        &all_cf_options.values,
        &cfs.values,
        @ptrCast(&err_cstr),
    );
    try c_helper.checkRocksdbErr(err_cstr, @src(), last_diag);
    return .{ .db = db, .cfs = cfs };
}

pub fn deinit(self: Storage) void {
    var iter = std.mem.reverseIterator((&self.cfs.values)[0..]);
    while (iter.next()) |cf_handle| {
        c.rocksdb_column_family_handle_destroy(cf_handle);
    }
    c.rocksdb_close(self.db);
}
