const std = @import("std");
const zargs = @import("zargs");
const c = @cImport({
    @cInclude("git2.h");
    @cInclude("rocksdb/c.h");
});

pub fn main() !void {
    // 使用c分配器的原因：
    // 原则上，在当前0.14版本，根分配器的最佳实践是搭配使用DebugAllocator和smp_allocator。参见<https://github.com/ziglang/zig/pull/22808>.
    // 但是，目前它们仍然存在一些悬而未决的不稳定问题，参见<https://github.com/ziglang/zig/issues/18775>与相关评论。
    // 在我需要链接C语言库的前提下，DebugAllocator虽然可以帮助我调试内存泄漏，但是无法检查我对C语言库提供的对象的内存使用问题。
    // 总得来说，c_allocator是一个速度比较良好，且可以使用valgrind对所有的对象一致地进行C风格检查的分配器，且目前比较可预测，没有未解决的坑。
    const root_allocator = std.heap.c_allocator;
    const runner = @import("cli.zig").parseArgs(root_allocator);
    try runner.run();
    _ = c.git_libgit2_init();
    _ = c.git_libgit2_shutdown();
}
test "libgit2 test" {
    _ = c.git_libgit2_init();
    _ = c.git_libgit2_shutdown();
}
test "rocksdb test" {
    const options = c.rocksdb_options_create();
    c.rocksdb_options_set_create_if_missing(options, 1);
    c.rocksdb_options_destroy(options);
}
