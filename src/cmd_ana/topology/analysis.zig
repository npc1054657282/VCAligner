const std = @import("std");
const zargs = @import("zargs");
const vcaligner = @import("vcaligner");
const diag = vcaligner.diag;
const AnaRunner = @import("AnaRunner.zig");

pub fn analysis(noalias runconf: *const AnaRunner, gpa: vcaligner.gpa.Concurrent, last_diag: *diag.Diagnostic) !void {
    // 仅前半部分需要并行解析的部分需要频繁复用pool，此为其生存期。
    pool_lifetime: {
        var pool: vcaligner.Pool = undefined;
        try pool.init(.{ .allocator = gpa.allocator, .n_jobs = runconf.n_jobs - 1 });
        defer pool.deinit();
        break :pool_lifetime;
    }

    _ = last_diag;
}
