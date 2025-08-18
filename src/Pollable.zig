const std = @import("std");
const Pollable = @This();

runFn: *const fn (*const Pollable, Operation) ?Status,

pub const Operation = enum {
    run,
    query_status,
    destroy,
};
pub const Status = enum {
    ready,
    done,
};
pub fn create(comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func)), allocator: std.mem.Allocator) !Pollable {
    std.debug.assert(@typeInfo(func).@"fn".return_type.? == Status);
    const Closure = struct {
        arguments: @TypeOf(args),
        allocator: std.mem.Allocator,
        status: Status = .ready,
        runnable: Pollable = .{ .runFn = runFn },
        fn runFn(runnable: *const Pollable, operation: Operation) ?Status {
            const closure: *@This() = @alignCast(@fieldParentPtr("runnable", runnable));
            return switch (operation) {
                .run => switch (closure.status) {
                    .ready => blk: {
                        closure.status = @call(.auto, func, closure.arguments);
                        break :blk closure.status;
                    },
                    .done => .done,
                },
                .query_status => closure.status,
                .destroy => blk: {
                    closure.allocator.destroy(closure);
                    break :blk null;
                },
            };
        }
    };
    const closure = try allocator.create(Closure);
    closure.* = .{ .arguments = args, .allocator = allocator };
    return &closure.runnable;
}

pub fn operate(self: *const Pollable, operation: Operation) ?Status {
    return self.runFn(self, operation);
}
