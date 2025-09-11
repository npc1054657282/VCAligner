const std = @import("std");

const CrashDump = @This();

allocator: std.mem.Allocator,
registry: std.AutoHashMapUnmanaged(DumpableId, *Dumpable),

pub const DumpableId = struct {
    name: [16:0]u8,
    id: usize,
};
pub const Dumpable = struct {
    dumpFn: *const fn (*Dumpable) void,
};

pub fn init(allocator: std.mem.Allocator) CrashDump {
    return .{ .allocator = allocator, .registry = .empty };
}

pub fn deinit(self: *CrashDump) void {
    self.registry.deinit(self.allocator);
}

pub fn reg(self: *CrashDump, comptime name: []const u8, id: usize, dumpable: *Dumpable) !void {
    const did: DumpableId = .{
        .name = blk: {
            var dest: [16:0]u8 = @splat(0);
            @memcpy(dest[0..name.len], name);
            break :blk dest;
        },
        .id = id,
    };
    try self.registry.put(self.allocator, did, dumpable);
}

pub fn unreg(self: *CrashDump, comptime name: []const u8, id: usize) void {
    const did: DumpableId = .{
        .name = blk: {
            var dest: [16:0]u8 = @splat(0);
            @memcpy(dest[0..name.len], name);
            break :blk dest;
        },
        .id = id,
    };
    // 取消注册前，打印一下日志内容：
    if (self.registry.get(did)) |dumpable| {
        std.log.info("unreg log: {s}-{d}", .{ name, id });
        dumpable.dumpFn(dumpable);
    }
    if (!self.registry.remove(did)) {
        std.log.warn("Crash dump unreg failed.\n", .{});
    }
}

pub fn dumpAndCrash(self: *CrashDump) noreturn {
    var iter = self.registry.iterator();
    while (iter.next()) |entry| {
        std.log.info("cuash log: {s}-{d}", .{ entry.key_ptr.name, entry.key_ptr.id });
        entry.value_ptr.dumpFn(entry.value_ptr);
    }
    std.process.abort();
}
