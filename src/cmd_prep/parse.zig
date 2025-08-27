const std = @import("std");
const Channel = @import("PrepRunner.zig").Channel;
const c_helper = @import("gvca").c_helper;
const c = c_helper.c;
const PrepRunner = @import("PrepRunner.zig");
const diag = @import("gvca").diag;

pub const Parsing = struct {
    // 线程局部分配器。虽然本程序实践中使用c_allocator，因此实际上没有什么局部性。
    allocator: std.mem.Allocator,
    diagnostics_arena: std.heap.ArenaAllocator,
    diagnostics: diag.Diagnostics,
    pub fn init(self: *Parsing) void {
        self.allocator = std.heap.c_allocator;
        self.diagnostics_arena = std.heap.ArenaAllocator.init(self.allocator);
        self.diagnostics = .{ .arena = self.diagnostics_arena };
    }
    pub fn deinit(self: *Parsing) void {
        self.diagnostics_arena.deinit();
        self.* = undefined;
    }
};

pub fn task(thrd_id: usize, gctx: *PrepRunner, commit_id: c.git_oid, commit_seq: usize) void {
    const lctx = &gctx.parsers.lctxs.items[thrd_id];
    const allocator = lctx.allocator;
    const last_diag = &lctx.diagnostics.last_diagnostic;

    _ = allocator;
    _ = commit_seq;
    var commit: ?*c.git_commit = undefined;
    const git_error_code = c.git_commit_lookup(&commit, gctx.repo, &commit_id);
    c_helper.gitErrorCodeToZigError(git_error_code, last_diag) catch |err| {
        lctx.diagnostics.log_all(err);
        lctx.diagnostics.clear();
        std.process.abort();
    };
}
