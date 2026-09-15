pub fn BareUnion(T: type) type {
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
