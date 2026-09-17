const std = @import("std");
pub fn BareUnion(comptime T: type) type {
    const u = switch (@typeInfo(T)) {
        .@"union" => |u| u,
        else => @compileError("expected union type, found '" ++ @typeName(T) ++ "'"),
    };
    return @Type(.{ .@"union" = .{
        .layout = u.layout,
        .tag_type = null,
        .fields = u.fields,
        .decls = &.{},
    } });
}

pub fn bareToTagged(comptime T: type, bare: BareUnion(T), tag: std.meta.Tag(T)) T {
    switch (tag) {
        inline else => |comptime_tag| {
            return @unionInit(T, @tagName(comptime_tag), @field(bare, @tagName(comptime_tag)));
        },
    }
}
pub fn taggedToBare(tagged: anytype) BareUnion(@TypeOf(tagged)) {
    switch (tagged) {
        inline else => |payload, comptime_tag| {
            const tag_name = @tagName(comptime_tag);
            return @unionInit(BareUnion(@TypeOf(tagged)), tag_name, payload);
        },
    }
}
