const std = @import("std");
const vcaligner = @import("vcaligner");
const c = vcaligner.c_helper.c;
const CumulativeStorage = @import("CumulativeStorage.zig");

fn write(
    noalias storage: *const CumulativeStorage,
    write_batch_watermark: c_int,
    gpa: vcaligner.gpa.Concurrent,
    last_diag: *vcaligner.diag.Diagnostic,
) !void {
    _ = storage;
    _ = write_batch_watermark;
    _ = gpa;
    _ = last_diag;
}
