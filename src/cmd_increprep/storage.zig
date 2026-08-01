const std = @import("std");
const vcaligner = @import("vcaligner");
const c_helper = vcaligner.c_helper;
const c = c_helper.c;
pub const Storage = union(enum) {
    valid: struct {
        db: *c.rocksdb_t,
        cf_handles: std.enums.EnumArray(vcaligner.rocksdb_custom.CollumFamily, ?*c.rocksdb_column_family_handle_t),
    },
    invalid: void,
};
