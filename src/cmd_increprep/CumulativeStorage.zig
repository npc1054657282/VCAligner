/// 包括可以一边解析一边写入的列族句柄的数据库对象。不包括Full-Rebuild的pr2pi列族。
const std = @import("std");
const vcaligner = @import("vcaligner");
const c = vcaligner.c_helper.c;

db: *c.rocksdb_t,
cf_handles: std.enums.EnumArray(CollumFamily, *c.rocksdb_column_family_handle_t),

pub const CollumFamily = enum(std.meta.Tag(vcaligner.rocksdb_custom.CollumFamily)) {
    bpi_ci = @intFromEnum(vcaligner.rocksdb_custom.CollumFamily.b_pi_bpi),
    pi_p = @intFromEnum(vcaligner.rocksdb_custom.CollumFamily.pi_p),
    b_pi_bpi = @intFromEnum(vcaligner.rocksdb_custom.CollumFamily.b_pi_bpi),
    ci_c = @intFromEnum(vcaligner.rocksdb_custom.CollumFamily.ci_c),
};
