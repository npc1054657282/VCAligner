const std = @import("std");

test "atomic" {
    var i: std.atomic.Value(u128) = .init(std.math.maxInt(u128));
    _ = i.fetchAdd(3, .monotonic);
    std.debug.print("{d}\n", .{i.load(.monotonic)});
    var j: std.atomic.Value(usize) = .init(std.math.maxInt(usize));
    _ = j.fetchAdd(1, .monotonic);
    std.debug.print("{d}\n", .{j.load(.monotonic)});
}

test "splat" {
    const Point = struct { x: i8, y: i8 };
    const ten_default_point: [10]Point = @splat(.{ .x = 3, .y = 4 });
    try std.testing.expectEqual(ten_default_point[8].x, 3);
}

test "struct struct" {
    const Point = struct {
        x: i8,
        y: i8,
    };
    const P = struct {
        Point,
    };
    const point: P = .{
        .{ .x = 1, .y = 2 },
    };
    try std.testing.expectEqual(point.@"0".x, 1);
}

fn getTuple(i: u8) !struct { u8, []const u8 } {
    return switch (i) {
        0 => error.E,
        1...8 => .{
            i + 1,
            "hello, world",
        },
        else => .{
            i,
            "fake news",
        },
    };
}

fn getTuple2(i: u8) ?struct { u8, []const u8 } {
    return switch (i) {
        0 => null,
        1...8 => .{
            i + 1,
            "hello, world",
        },
        else => .{
            i,
            "fake news",
        },
    };
}

test "destructuring" {
    var i: u8 = 0;
    const a, const txt = while (true) : (i += 1) {
        break getTuple(i) catch continue;
    };
    std.debug.print("a = {d}, txt = {s}\n", .{ a, txt });
    i = 9;
    while (true) : (i -= 1) {
        const b, const txt2 = getTuple2(i) orelse break;
        std.debug.print("b = {d}, txt2 = {s}\n", .{ b, txt2 });
    }
}

fn NewUnion(l: comptime_int) type {
    comptime std.debug.assert(l < 8 * @sizeOf(usize));
    var union_fields: [l]std.builtin.Type.UnionField = undefined;
    var enum_fields: [l]std.builtin.Type.EnumField = undefined;
    for (0..l) |i| {
        const tag_name = std.fmt.comptimePrint("lower{d}", .{1 << i});
        const FieldType = std.meta.Int(.unsigned, i);
        const new_union_field: std.builtin.Type.UnionField = .{
            .name = tag_name,
            .type = FieldType,
            .alignment = @alignOf(FieldType),
        };
        const new_enum_field: std.builtin.Type.EnumField = .{
            .name = tag_name,
            .value = i,
        };
        union_fields[i] = new_union_field;
        enum_fields[i] = new_enum_field;
    }
    const TagType = @Type(.{ .@"enum" = .{
        .tag_type = std.math.IntFittingRange(0, l - 1),
        .fields = &enum_fields,
        .decls = &.{},
        .is_exhaustive = true,
    } });
    return @Type(.{ .@"union" = .{
        .layout = .auto,
        .tag_type = TagType,
        .fields = &union_fields,
        .decls = &.{},
    } });
}

test NewUnion {
    const T = NewUnion(16);
    const u: T = .{ .lower128 = 7 };
    switch (u) {
        inline else => |v, tag| {
            try std.testing.expect(std.mem.eql(u8, @tagName(tag), "lower128"));
            try std.testing.expect(v == 7);
        },
    }
}

const Struct1 = struct {
    v: usize,
};
const Struct2 = struct {
    v: usize,
};
const Tuple1 = struct {
    usize,
};
const Tuple2 = struct {
    usize,
};

test "sameStruct" {
    try std.testing.expect(Struct1 != Struct2);
    try std.testing.expect(Tuple1 == Tuple2);
}

fn MacroProbe(T: type) type {
    return struct {
        x: T,
        pub const Macro = MacroProbe;
    };
}
test MacroProbe {
    const MacroProbeU8 = MacroProbe(u8);
    try std.testing.expect(MacroProbeU8.Macro == MacroProbe);
}

fn tupleOrError(n: u8) !struct { u8, u8 } {
    if (n == 255) return error.TestError;
    return .{ n, n + 1 };
}
test tupleOrError {
    var n: u8 = 255;
    const ret1, const ret2 = tupleOrError(n) catch blk: {
        while (true) {
            n = n >> 1;
            break :blk tupleOrError(n) catch continue;
        }
    };
    try std.testing.expect(ret1 == 127 and ret2 == 128);
}

fn TypeChange(comptime T: type) type {
    if (T == u8) return u32 else return u64;
}

fn zero(x: anytype) TypeChange(@TypeOf(x)) {
    return 0;
}

test zero {
    const return_type = @typeInfo(@TypeOf(zero)).@"fn".return_type;
    if (return_type) |T| {
        std.debug.print("{s}", .{@typeName(T)});
    } else std.debug.print("null", .{});
}

fn status_machine(i: *u8) bool {
    if (i.* > 0) {
        i.* -= 1;
        return false;
    } else return true;
}

fn throw(i: u8) !u8 {
    if (i > 0) {
        std.debug.print("error", .{});
        return error.SomeError;
    } else {
        std.debug.print("success", .{});
        return 200;
    }
}

test status_machine {
    var i: u8 = 4;
    const result = throw(i) catch result_blk: {
        sw: switch (status_machine(&i)) {
            false => break :result_blk throw(i) catch continue :sw status_machine(&i),
            true => break :sw,
        }
        break :result_blk 100;
    };
    std.debug.print("{d}", .{result});
}
