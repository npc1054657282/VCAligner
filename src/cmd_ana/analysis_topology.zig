const std = @import("std");
const zargs = @import("zargs");
const vcaligner = @import("vcaligner");
const diag = vcaligner.diag;
const AnaTopologyRunner = @import("AnaTopologyRunner.zig");

pub fn analysis(noalias runconf: *const AnaTopologyRunner, gpa: vcaligner.gpa.Concurrent, last_diag: *diag.Diagnostic) !void {
    _ = runconf;
    _ = gpa;
    _ = last_diag;
}
