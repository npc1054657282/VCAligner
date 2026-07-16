const vcaligner = @import("vcaligner.zig");
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
pub const ErrorEnumFromErrorSet = @import("error_enum.zig").ErrorEnumFromErrorSet;
// 0.16起，zig的Arena采用线程安全模式。我的项目里不会存在任何线程安全需求的Arena，因此我会使用原线程不安全版本。
// 虽然当前代码仍然基于0.15.2版本，但出于向前兼容考虑，定义`StArena`为线程不安全的Arena，将尽可能替代源代码里标准库的Arena。
pub const StArena = @import("thread_unsafe_arena.zig").ArenaAllocator;

pub const runtime_safety = switch (@import("builtin").mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};

// 全局变量，用于注册崩溃日志。
pub var crash_dump: CrashDump = undefined;

/// Gpa指本程序使用的特定种类分配器，此类分配器有这样的特点：
/// 1. 线程安全。允许多个线程并发地基于该分配器进行操作。
/// 2. 每次分配需要一次释放。
/// 本程序如果某处传入的分配器有这样的限制需求，则使用`Gpa`而非`Allocator`。
pub const Gpa = struct {
    allocator: std.mem.Allocator,
    // 使用c分配器的原因：
    // 原则上，在当前0.14版本，根分配器的最佳实践是搭配使用DebugAllocator和smp_allocator。参见<https://github.com/ziglang/zig/pull/22808>.
    // 但是，目前它们仍然存在一些悬而未决的不稳定问题，参见<https://github.com/ziglang/zig/issues/18775>与相关评论。
    // 在我需要链接C语言库的前提下，DebugAllocator虽然可以帮助我调试内存泄漏，但是无法检查我对C语言库提供的对象的内存使用问题。
    // 总得来说，c_allocator是一个速度比较良好，且可以使用valgrind对所有的对象一致地进行C风格检查的分配器，且目前比较可预测，没有未解决的坑。
    pub const Instance = CAllocatorAsGpaInstance;
};

const CAllocatorAsGpaInstance = struct {
    pub fn init() CAllocatorAsGpaInstance {
        return .{};
    }
    pub fn deinit(self: *CAllocatorAsGpaInstance) void {
        _ = self;
    }
    pub fn gpa(self: *CAllocatorAsGpaInstance) Gpa {
        _ = self;
        return .{ .allocator = std.heap.c_allocator };
    }
};

const GlobalDebugAllocatorAsGpaInstance = struct {
    pub var debug_allocator_instance: std.heap.DebugAllocator(.{}) = .init;
    pub fn init() GlobalDebugAllocatorAsGpaInstance {
        return .{};
    }
    pub fn deinit(self: *GlobalDebugAllocatorAsGpaInstance) void {
        _ = self;
        debug_allocator_instance.deinit();
    }
    pub fn gpa(self: *GlobalDebugAllocatorAsGpaInstance) Gpa {
        _ = self;
        return .{ .allocator = debug_allocator_instance.allocator() };
    }
};

const SmpAllocatorAsGpaInstance = struct {
    pub fn init() SmpAllocatorAsGpaInstance {
        return .{};
    }
    pub fn deinit(self: *SmpAllocatorAsGpaInstance) void {
        _ = self;
    }
    pub fn gpa(self: *SmpAllocatorAsGpaInstance) Gpa {
        _ = self;
        return .{ .allocator = std.heap.smp_allocator };
    }
};

pub fn getAllocator() std.mem.Allocator {
    // if (runtime_safety) return gpa.allocator();
    return std.heap.c_allocator;
}

pub fn main() !void {
    var gpa_instance: Gpa.Instance = .init();
    defer gpa_instance.deinit();
    const gpa = gpa_instance.gpa();
    crash_dump = .init(gpa.allocator);
    defer crash_dump.deinit();
    var diagnostics: diag.Diagnostics = .{ .arena = std.heap.ArenaAllocator.init(gpa.allocator) };
    defer diagnostics.arena.deinit();
    var cli_runner = try cli.parseArgs(gpa.allocator);
    defer cli_runner.deinit(gpa.allocator);
    cli_runner.run(gpa, &diagnostics.last_diagnostic) catch |err| {
        diagnostics.log_all(err);
        diagnostics.clear();
    };
    std.log.debug("VCAligner End.\n", .{});
}

test {
    std.testing.refAllDecls(@This());
}
