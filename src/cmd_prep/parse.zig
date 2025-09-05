const std = @import("std");
const Channel = @import("PrepRunner.zig").Channel;
const gvca = @import("gvca");
const c_helper = gvca.c_helper;
const c = c_helper.c;
const PrepRunner = @import("PrepRunner.zig");

const diag = @import("gvca").diag;

pub const Parsing = struct {
    // 线程局部分配器。虽然本程序实践中使用c_allocator，因此实际上没有什么局部性。
    allocator: std.mem.Allocator,
    diagnostics_arena: std.heap.ArenaAllocator,
    diagnostics: diag.Diagnostics,
    producer_local: PrepRunner.Queue.ProducerLocal,
    comptime flush_threshold: usize = 512,
    // 以下内容为当前任务的缓存，下一个任务起重置。
    current_task: struct {
        arena: std.heap.ArenaAllocator,
        commit_seq: PrepRunner.CommitSeq,
    },
    // 以下内容为当前批次内容，flush过了就重置。
    to_flush: PrepRunner.Parsed,

    pub fn init(self: *Parsing, channel: *Channel) void {
        self.allocator = gvca.getAllocator();
        self.diagnostics_arena = std.heap.ArenaAllocator.init(self.allocator);
        self.diagnostics = .{ .arena = self.diagnostics_arena };
        self.producer_local = channel.mpsc_queue_ref.initProducerLocal();
    }
    pub fn deinit(self: *Parsing) void {
        self.diagnostics_arena.deinit();
        self.* = undefined;
    }
};

pub fn task(thrd_id: usize, gctx: *PrepRunner, commit_hash: c.git_oid, commit_seq: PrepRunner.CommitSeq) void {
    const lctx: *Parsing = &gctx.parsers.lctxs.items[thrd_id];
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
        // 原理上，`to_flush`每次重置的arena使用的是一个新创建的分配器。此处实践总是使用c分配器。
        .arena = .init(gvca.getAllocator()),
        .commit_hash = commit_hash,
        .commit_seq = undefined,
        .parsed_units = .empty,
        .keys_list = .empty,
        .values_list = undefined,
    };
    lctx.to_flush.commit_seq = lctx.to_flush.arena.allocator().create(PrepRunner.CommitSeq) catch |err| {
        lctx.diagnostics.log_all(err);
        lctx.diagnostics.clear();
        std.process.abort();
    };
    lctx.to_flush.commit_seq.* = commit_seq;
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
    parse_tree(gctx, lctx, tree, &@as([0]u8, .{})) catch |err| {
        lctx.diagnostics.log_all(err);
        lctx.diagnostics.clear();
        std.process.abort();
    };
    // 任务结束时最后刷新一次。
    flush_relation_batch(gctx, lctx) catch |err| {
        lctx.diagnostics.log_all(err);
        lctx.diagnostics.clear();
        std.process.abort();
    };
    return;
}

// XXX: 子树存在一个或许可能降低内存分配量的方案：每个线程维护一个树，每一级分析都在本地树里搜索和创建文件目录节点。
// 或许可以降低内存分配量，但我相信瓶颈不在解析这一端而在rocksdb写入这一端，所以提升解析端效率而消耗更大内存可能是得不偿失的。
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
                try append_relation(gctx, lctx, full_path, entry_oid);
            },
            else => {},
        }
    }
    return;
}

fn append_relation(gctx: *PrepRunner, lctx: *Parsing, path: []u8, blob_oid: *const c.git_oid) !void {
    try lctx.to_flush.parsed_units.append(lctx.to_flush.arena.allocator(), .{
        .path = path,
        .key = .{
            .path_seq = undefined,
            .blob_hash = blob_oid.id,
        },
    });
    const key_ptr = &lctx.to_flush.parsed_units.items[lctx.to_flush.parsed_units.items.len - 1].key;
    try lctx.to_flush.keys_list.append(lctx.to_flush.arena.allocator(), key_ptr);
    if (lctx.to_flush.parsed_units.items.len >= lctx.flush_threshold) {
        try flush_relation_batch(gctx, lctx);
        lctx.to_flush = .{
            .arena = .init(gvca.getAllocator()),
            .commit_hash = null,
            .commit_seq = undefined,
            .parsed_units = .empty,
            .keys_list = .empty,
            .values_list = undefined,
        };
        lctx.to_flush.commit_seq = try lctx.to_flush.arena.allocator().create(PrepRunner.CommitSeq);
        lctx.to_flush.commit_seq.* = lctx.current_task.commit_seq;
    }
}

fn flush_relation_batch(gctx: *PrepRunner, lctx: *Parsing) !void {
    lctx.to_flush.values_list = try lctx.to_flush.arena.allocator().alloc(*PrepRunner.CommitSeq, lctx.to_flush.parsed_units.items.len);
    @memset(lctx.to_flush.values_list, lctx.to_flush.commit_seq);
    const ticket, const to_produce: *PrepRunner.Parsed = gctx.channel.claimProduce(&lctx.producer_local, null);
    defer gctx.channel.publishProducedUnsafe(ticket);
    // ArenaAllocator和ArrayList经过源码验证，直接拷贝均安全。
    to_produce.* = lctx.to_flush;
    lctx.to_flush = undefined;
}
