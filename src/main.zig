const std = @import("std");
const zargs = @import("zargs");
const error_helper = @import("error.zig");
const c_helper = @import("c.zig");

pub fn main() !void {
    // 使用c分配器的原因：
    // 原则上，在当前0.14版本，根分配器的最佳实践是搭配使用DebugAllocator和smp_allocator。参见<https://github.com/ziglang/zig/pull/22808>.
    // 但是，目前它们仍然存在一些悬而未决的不稳定问题，参见<https://github.com/ziglang/zig/issues/18775>与相关评论。
    // 在我需要链接C语言库的前提下，DebugAllocator虽然可以帮助我调试内存泄漏，但是无法检查我对C语言库提供的对象的内存使用问题。
    // 总得来说，c_allocator是一个速度比较良好，且可以使用valgrind对所有的对象一致地进行C风格检查的分配器，且目前比较可预测，没有未解决的坑。
    const root_allocator = std.heap.c_allocator;
    var runner = try @import("cli.zig").parseArgs(root_allocator);
    defer runner.deinit(root_allocator);
    runner.run(root_allocator) catch |err| {
        switch (err) {
            inline else => |e| {
                // 尽管采用了动态分派，但是如果强制comptime执行`inErrorSet`会出错：超过1000个选项。
                // 而不强制comptime执行，@errorCast到指定错误集就会失败，无视了Libgit2Error以外的其他错误无法通过校验的事实。
                // 不过有趣的是，如果不用静态分派，纯运行时使用`inErrorSet`也会出错，要求错误必须时编译时已知值。
                // 我个人的一种推测是，error的switch可能并不是switch所有错误，而是switch的整个整数空间……？
                // 而zig的编译期函数有可能会对过大的空间在静态分派时自动转换为运行时，代价是后续无法推断错误具体类型，所以不能@errorCast？
                if (error_helper.inErrorSet(e, c_helper.Libgit2Error)) {
                    c_helper.logLibgit2Error(e, runner.getLastError().?);
                } else {
                    return e;
                }
            },
        }
    };
}
