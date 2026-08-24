pub fn ErrorEnumFromErrorSet(
    comptime ErrorSet: type,
    comptime BackingInt: type,
    comptime start_value: comptime_int,
    comptime step: comptime_int,
) type {
    // 关于此处的`.?`，如果此类型信息为`null`意思是`anyerror`，我们不支持`anyerror`。
    const error_set_info = @typeInfo(ErrorSet).error_set.?;
    const enum_fields = comptime blk: {
        var enum_fields: [error_set_info.len]std.builtin.Type.EnumField = undefined;
        var value = start_value;
        for (error_set_info, 0..) |err_info, i| {
            enum_fields[i] = .{ .name = err_info.name, .value = value };
            value += step;
        }
        break :blk enum_fields;
    };
    return struct {
        pub const E: type = @Type(.{ .@"enum" = .{
            .tag_type = BackingInt,
            .fields = &enum_fields,
            .decls = &.{},
            .is_exhaustive = true,
        } });
        e: E,
        pub fn fromError(err: ErrorSet) @This() {
            return switch (err) {
                inline else => |comptime_err| .{ .e = @field(E, @errorName(comptime_err)) },
            };
        }
        pub fn toError(self: @This()) ErrorSet {
            return switch (self.e) {
                inline else => |e| @field(ErrorSet, @tagName(e)),
            };
        }
        pub fn fromBackingInt(backing: BackingInt) @This() {
            return .{ .e = @enumFromInt(backing) };
        }
        pub fn toBackingInt(self: @This()) BackingInt {
            return @intFromEnum(self.e);
        }
    };
}

const std = @import("std");

test ErrorEnumFromErrorSet {
    const ErrorSet = error{
        Error1,
        Error2,
        Error3,
    };
    const ErrorEnum = ErrorEnumFromErrorSet(ErrorSet, u8, 1, 1);
    var err1: ErrorSet = error.Error3;
    _ = &err1;
    const e1: ErrorEnum = .fromError(err1);
    try std.testing.expectEqual(@as(ErrorEnum, .{ .e = .Error3 }), e1);
    const back_to_err1 = e1.toError();
    try std.testing.expectEqual(error.Error3, back_to_err1);
    const ev1 = e1.toBackingInt();
    try std.testing.expectEqual(3, ev1);
    var ev2: u8 = 2;
    _ = &ev2;
    const e2: ErrorEnum = .fromBackingInt(ev2);
    try std.testing.expectEqual(@as(ErrorEnum, .{ .e = .Error2 }), e2);
    const err2: ErrorSet = e2.toError();
    try std.testing.expectEqual(error.Error2, err2);
}
