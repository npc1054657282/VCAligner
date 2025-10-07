const gvca = @import("gvca.zig");
const std = @import("std");
const zargs = @import("zargs");
pub const cli = @import("cli.zig");
pub const diag = @import("diagnostics.zig");
pub const c_helper = @import("c.zig");
pub const MpscChannel = @import("mpsc_channel.zig").MpscChannel;
pub const Pool = @import("Pool.zig");
pub const CrashDump = @import("CrashDump.zig");
pub const rocksdb_custom = @import("rocksdb_custom.zig");
pub const commit_range = @import("commit_range.zig");
pub const pid = @import("pid.zig");

const runtime_safety = switch (@import("builtin").mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};

// 全局变量，用于注册崩溃日志。
pub var crash_dump: CrashDump = undefined;

// var gpa: if (runtime_safety) std.heap.DebugAllocator(.{}) else void = if (runtime_safety) .init else {};

pub fn getAllocator() std.mem.Allocator {
    // if (runtime_safety) return gpa.allocator();
    return std.heap.c_allocator;
}

pub fn main() !void {
    // 使用c分配器的原因：
    // 原则上，在当前0.14版本，根分配器的最佳实践是搭配使用DebugAllocator和smp_allocator。参见<https://github.com/ziglang/zig/pull/22808>.
    // 但是，目前它们仍然存在一些悬而未决的不稳定问题，参见<https://github.com/ziglang/zig/issues/18775>与相关评论。
    // 在我需要链接C语言库的前提下，DebugAllocator虽然可以帮助我调试内存泄漏，但是无法检查我对C语言库提供的对象的内存使用问题。
    // 总得来说，c_allocator是一个速度比较良好，且可以使用valgrind对所有的对象一致地进行C风格检查的分配器，且目前比较可预测，没有未解决的坑。
    const root_allocator = std.heap.c_allocator;
    // defer {
    //     if (runtime_safety) {
    //         const leak = gpa.deinit();
    //         if (leak == .leak) {
    //             std.log.warn("memory leak detected.\n", .{});
    //         }
    //     }
    // }
    crash_dump = .init(root_allocator);
    defer crash_dump.deinit();
    const diagnostics_arena = std.heap.ArenaAllocator.init(root_allocator);
    defer diagnostics_arena.deinit();
    var diagnostics: diag.Diagnostics = .{ .arena = diagnostics_arena };
    var cli_runner = try cli.parseArgs(root_allocator);
    defer cli_runner.deinit(root_allocator);
    cli_runner.run(root_allocator, &diagnostics.last_diagnostic) catch |err| {
        diagnostics.log_all(err);
        diagnostics.clear();
    };
    std.log.info("Gvca End.\n", .{});
}

test {
    std.testing.refAllDecls(@This());
}
