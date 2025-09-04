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
    producer_local: PrepRunner.Queue.ProducerLocal,
    comptime flush_threshold: usize = 1024,
    // 以下内容为当前任务的缓存，下一个任务起重置。
    current_task: struct {
        arena: std.heap.ArenaAllocator,
        commit_seq: usize,
    },
    // 以下内容为当前批次内容，flush过了就重置。
    to_flush: PrepRunner.Parsed,

    pub fn init(self: *Parsing, channel: *Channel) void {
        self.allocator = std.heap.c_allocator;
        self.diagnostics_arena = std.heap.ArenaAllocator.init(self.allocator);
        self.diagnostics = .{ .arena = self.diagnostics_arena };
        self.producer_local = channel.mpsc_queue_ref.initProducerLocal();
    }
    pub fn deinit(self: *Parsing) void {
        self.diagnostics_arena.deinit();
        self.* = undefined;
    }
};

pub fn task(thrd_id: usize, gctx: *PrepRunner, commit_hash: c.git_oid, commit_seq: usize) void {
    const lctx = &gctx.parsers.lctxs.items[thrd_id];
    const allocator = lctx.allocator;
    const last_diag = &lctx.diagnostics.last_diagnostic;
    // 进入解析，降低积压的`task_in_queue_count`
    _ = gctx.parsers.task_in_queue_count.fetchSub(1, .release);

    lctx.current_task = .{
        .arena = .init(allocator),
        .commit_seq = commit_seq,
    };
    defer lctx.current_task.arena.deinit();
    lctx.to_flush = .{
        .arena = .init(allocator),
        .commit_hash = commit_hash,
        .commit_seq = commit_seq,
        .parsed_units = .empty,
    };
    // 交由写者释放。

    const commit: *c.git_commit = blk: {
        var commit: ?*c.git_commit = undefined;
        const git_error_code = c.git_commit_lookup(&commit, gctx.repo, &commit_hash);
        c_helper.gitErrorCodeToZigError(git_error_code, last_diag) catch |err| {
            lctx.diagnostics.log_all(err);
            lctx.diagnostics.clear();
            std.process.abort();
        };
        break :blk commit.?;
    };
    defer c.git_commit_free(commit);
    const tree: *c.git_tree = blk: {
        var tree: ?*c.git_tree = undefined;
        const git_error_code = c.git_commit_tree(&tree, commit);
        c_helper.gitErrorCodeToZigError(git_error_code, last_diag) catch |err| {
            lctx.diagnostics.log_all(err);
            lctx.diagnostics.clear();
            std.process.abort();
        };
        break :blk tree.?;
    };
    defer c.git_tree_free(tree);
}

fn parse_tree(gctx: *PrepRunner, lctx: *Parsing, tree: *const c.git_tree, base_path: []const u8) !void {
    const entry_count = c.git_tree_entrycount(tree);
    for (0..entry_count) |i| {
        const entry = c.git_tree_entry_byindex(tree, i).?;
        const entry_type = c.git_tree_entry_type(entry);
        const entry_oid = c.git_tree_entry_id(entry);
        switch (entry_type) {
            c.GIT_OBJECT_TREE => deeper: {
                const subtree: *c.git_tree = blk: {
                    var subtree: ?*c.git_tree = undefined;
                    // 对于查找过程，报错是一个正常现象：空目录就会报错，因此无需错误退出。
                    if (c.git_tree_lookup(&subtree, gctx.repo, entry_oid) != 0) break :deeper;
                    break :blk subtree.?;
                };
                defer c.git_tree_free(subtree);
                const full_path = blk: {
                    const entry_name = c.git_tree_entry_name(entry);
                    const entry_name_slice: []const u8 = std.mem.span(entry_name);
                    if (base_path.len == 0) {
                        break :blk try lctx.current_task.arena.allocator().dupe(u8, entry_name_slice);
                    }
                    var builder: std.ArrayList(u8) = .empty;
                    try builder.appendSlice(lctx.current_task.arena.allocator(), base_path);
                    try builder.append(lctx.current_task.arena.allocator(), '/');
                    try builder.appendSlice(lctx.current_task.arena.allocator(), entry_name_slice);
                    break :blk try builder.toOwnedSlice(lctx.current_task.arena.allocator());
                };
                defer lctx.current_task.arena.allocator().free(full_path);
                try parse_tree(gctx, lctx, subtree, full_path);
            },
            c.GIT_OBJECT_BLOB => {
                // 不同之处在于此full path将移交writer，应使用to flush的arena且不会再释放。
                const full_path = blk: {
                    const entry_name = c.git_tree_entry_name(entry);
                    const entry_name_slice: []const u8 = std.mem.span(entry_name);
                    if (base_path.len == 0) {
                        break :blk try lctx.to_flush.arena.allocator().dupe(u8, entry_name_slice);
                    }
                    var builder: std.ArrayList(u8) = .empty;
                    try builder.appendSlice(lctx.to_flush.arena.allocator(), base_path);
                    try builder.append(lctx.to_flush.arena.allocator(), '/');
                    try builder.appendSlice(lctx.to_flush.arena.allocator(), entry_name_slice);
                    break :blk try builder.toOwnedSlice(lctx.to_flush.arena.allocator());
                };
                try append_relation(gctx, lctx, full_path, entry_oid.*);
            },
            else => {},
        }
    }
    return;
}

fn append_relation(gctx: *PrepRunner, lctx: *Parsing, path: []u8, blob_hash: c.git_oid) !void {
    try lctx.to_flush.parsed_units.append(lctx.to_flush.arena.allocator(), .{
        .path = path,
        .blob = blob_hash,
    });
    if (lctx.to_flush.parsed_units.len >= lctx.flush_threshold) {
        flush_relation_batch(gctx, lctx);
        lctx.to_flush = .{
            .arena = .init(lctx.allocator),
            .commit_hash = null,
            .commit_seq = lctx.current_task.commit_seq,
            .parsed_units = .empty,
        };
    }
}

fn flush_relation_batch(gctx: *PrepRunner, lctx: *Parsing) void {
    _ = gctx;
    _ = lctx;
}
