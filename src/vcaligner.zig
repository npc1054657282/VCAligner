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
pub const sub_enum = @import("sub_enum.zig");
// 0.16起，zig的Arena采用线程安全模式。我的项目里不会存在任何线程安全需求的Arena，因此我会使用原线程不安全版本。
// 虽然当前代码仍然基于0.15.2版本，但出于向前兼容考虑，定义`StArena`为线程不安全的Arena，将尽可能替代源代码里标准库的Arena。
pub const StArena = @import("thread_unsafe_arena.zig").ArenaAllocator;

pub const runtime_safety = switch (@import("builtin").mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};

// 全局变量，用于注册崩溃日志。
pub var crash_dump: CrashDump = undefined;

/// gpa是本程序主要使用的分配器类型，此类分配器的每次分配都必须对应一次释放。
/// 本程序进一步使用`Concurrent`与`Owned`标注此类分配器的两种可能需求形态。
pub const gpa = struct {
    /// `gpa.Concurrent`可能并发地在多个线程上同时分配或释放。因此它必须是线程安全的。
    /// 如果它的实现缺少线程本地缓存优化，在多个线程分别包含它的一个实例有助于以锁分片的形式进一步减少竞争。
    /// 但注意即使有缓存优化，大概率仅限线程本地，即存在某种线程亲和性，这有助于其作为通用gpa的泛用性。
    /// 但在大量对象高频进行跨线程的非对称分配和释放时，很可能因远程归还风暴导致效率依旧不佳。
    /// 此时建议采用块级池化策略使用它。
    /// Instance必须包含`init() Self`、`deinit(self: *Self) void`、`gpac(self: *Self) Concurrent`三种方法。
    pub const Concurrent = struct {
        allocator: std.mem.Allocator,
        // XXX: 使用c分配器的原因：
        // 原则上，线程安全gpa的最佳实践是搭配使用DebugAllocator和smp_allocator。参见<https://github.com/ziglang/zig/pull/22808>.
        // 但是，目前它们仍然存在一些悬而未决的不稳定问题，参见<https://github.com/ziglang/zig/issues/18775>与相关评论。
        // 在我需要链接C语言库的前提下，DebugAllocator虽然可以帮助我调试内存泄漏，但是无法检查我对C语言库提供的对象的内存使用问题。
        // 总得来说，c_allocator是一个速度比较良好，且可以使用valgrind对所有的对象一致地进行C风格检查的分配器，且目前比较可预测，没有未解决的坑。
        pub const Instance = InstanceWrappedFrom(CAllocatorInstance);
        pub fn InstanceWrappedFrom(comptime AllocatorInstance: type) type {
            return struct {
                impl: AllocatorInstance,
                pub fn init() @This() {
                    return .{ .impl = .init() };
                }
                pub fn deinit(self: *@This()) void {
                    return self.impl.deinit();
                }
                pub fn gpac(self: *@This()) Concurrent {
                    return self.impl.gpac();
                }
            };
        }
    };
    /// `gpa.Owned`描述一种所有权独占的分配契约，其一个实例生命周期内服务一个特定的对象（数据结构）。
    /// 对象可能跨线程进行分配或释放，但这些行为在物理时间上不会同时发生。因此`gpa.Owned`允许非线程安全。
    /// `gpa.Owned.Instance`必须允许通过拷贝的方式转移所有权（即不存在自引用）。
    /// Instance必须包含`init() Self`、`deinit(self: *Self) void`、`gpao(self: *Self) Owned`三种方法。
    pub const Owned = struct {
        allocator: std.mem.Allocator,
        // XXX: 一个`Owned`可能实现是将本地线程缓存改为块缓存的SmpAllocator，或者一个精简掉泄露分析功能的线程不安全的DebugAllocator。
        // 但是实际上本程序对它的使用更多是出于逻辑上的，因此直接套用Concurrent的空实例即可。
        pub const Instance = InstanceWrappedFrom(CAllocatorInstance);
        pub fn InstanceWrappedFrom(comptime AllocatorInstance: type) type {
            return struct {
                impl: AllocatorInstance,
                pub fn init() @This() {
                    return .{ .impl = .init() };
                }
                pub fn deinit(self: *@This()) void {
                    return self.impl.deinit();
                }
                pub fn gpao(self: *@This()) Owned {
                    return self.impl.gpao();
                }
            };
        }
    };
};

const CAllocatorInstance = struct {
    pub fn init() CAllocatorInstance {
        return .{};
    }
    pub fn deinit(self: *CAllocatorInstance) void {
        _ = self;
    }
    pub fn gpac(self: *CAllocatorInstance) gpa.Concurrent {
        _ = self;
        return .{ .allocator = std.heap.c_allocator };
    }
    pub fn gpao(self: *CAllocatorInstance) gpa.Owned {
        _ = self;
        return .{ .allocator = std.heap.c_allocator };
    }
};

const DebugAllocatorInstance = struct {
    debug_allocator_instance: std.heap.DebugAllocator(.{}),
    pub fn init() DebugAllocatorInstance {
        return .{ .debug_allocator_instance = .init };
    }
    pub fn deinit(self: *DebugAllocatorInstance) void {
        // NOTE: 详细的泄露报告在析构过程中会自动产生。
        _ = self.debug_allocator_instance.deinit();
    }
    pub fn gpac(self: *DebugAllocatorInstance) gpa.Concurrent {
        return .{ .allocator = self.debug_allocator_instance.allocator() };
    }
    pub fn gpao(self: *DebugAllocatorInstance) gpa.Owned {
        return .{ .allocator = self.debug_allocator_instance.allocator() };
    }
};

const SmpAllocatorInstance = struct {
    pub fn init() SmpAllocatorInstance {
        return .{};
    }
    pub fn deinit(self: *SmpAllocatorInstance) void {
        _ = self;
    }
    pub fn gpac(self: *SmpAllocatorInstance) gpa.Concurrent {
        _ = self;
        return .{ .allocator = std.heap.smp_allocator };
    }
    pub fn gpao(self: *SmpAllocatorInstance) gpa.Owned {
        _ = self;
        return .{ .allocator = std.heap.smp_allocator };
    }
};

pub fn getAllocator() std.mem.Allocator {
    // if (runtime_safety) return gpa.allocator();
    return std.heap.c_allocator;
}

pub fn main() !void {
    var gpa_instance: gpa.Concurrent.Instance = .init();
    defer gpa_instance.deinit();
    const gpac = gpa_instance.gpac();
    crash_dump = .init(gpac.allocator);
    defer crash_dump.deinit();
    var diagnostics: diag.Diagnostics = .{ .arena = std.heap.ArenaAllocator.init(gpac.allocator) };
    defer diagnostics.arena.deinit();
    var cli_runner = try cli.parseArgs(gpac.allocator);
    defer cli_runner.deinit(gpac.allocator);
    cli_runner.run(gpac, &diagnostics.last_diagnostic) catch |err| {
        diagnostics.log_all(err);
        diagnostics.clear();
    };
    std.log.debug("VCAligner End.\n", .{});
}

test {
    std.testing.refAllDecls(@This());
}
