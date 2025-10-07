const std = @import("std");

pub const Pid = switch (@import("builtin").os.tag) {
    // [参见](https://mingw-w64-public.narkive.com/zGNfd7ET/patch-fix-data-types-pid-t-and-pid-t-for-64-bit-windows)
    // zig目前将windows的`pid_t`实现为一个不透明指针，这与POSIX标准中`pid_t`必须是一个有符号整数的定义不符。
    .windows => i32,
    else => std.c.pid_t,
};

pub fn get() Pid {
    const pid = std.c.getpid();
    return switch (@import("builtin").os.tag) {
        .windows => @truncate(@intFromPtr(pid)),
        else => pid,
    };
}
