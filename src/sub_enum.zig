const std = @import("std");

pub fn SubEnum(comptime ParentE: type, comptime subset: []const ParentE) type {
    const parent_info = @typeInfo(ParentE).@"enum";

    var fields: [subset.len]std.builtin.Type.EnumField = undefined;
    for (subset, 0..) |key, i| {
        fields[i] = .{
            .name = @tagName(key),
            .value = @intFromEnum(key),
        };
    }

    return @Type(.{
        .@"enum" = .{
            .tag_type = parent_info.tag_type,
            .fields = &fields,
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_exhaustive = true,
        },
    });
}

pub fn EnumArrayWithSubViewer(comptime E: type, comptime V: type) type {
    return struct {
        pub const EnumArray = std.enums.EnumArray(E, V);
        pub fn SubView(comptime subset: []const E) type {
            return struct {
                view: *EnumArray,
                pub const SubE = SubEnum(E, subset);
                pub fn get(self: @This(), key: SubE) V {
                    return self.view.get(@enumFromInt(@intFromEnum(key)));
                }
                pub fn getPtr(self: @This(), key: SubE) *V {
                    return self.view.getPtr(@enumFromInt(@intFromEnum(key)));
                }
                pub fn getPtrConst(self: @This(), key: SubE) *const V {
                    return self.view.getPtrConst(@enumFromInt(@intFromEnum(key)));
                }
                pub fn set(self: @This(), key: SubE, value: V) void {
                    self.view.set(@enumFromInt(@intFromEnum(key)), value);
                }
                // 关于迭代器：之所以不实现，是因为感觉不如自己基于SubEnum的enumField自己遍历key然后get来得方便。
                // 迭代器要认真实现的话也存在只读、读写等等版本，zig标准库都没全部实现，所以饶了我吧。
            };
        }
        pub fn SubViewConst(comptime subset: []const E) type {
            return struct {
                view: *const EnumArray,
                pub const SubE = SubEnum(E, subset);
                pub fn get(self: @This(), key: SubE) V {
                    return self.view.get(@enumFromInt(@intFromEnum(key)));
                }
                pub fn getPtrConst(self: @This(), key: SubE) *const V {
                    return self.view.getPtrConst(@enumFromInt(@intFromEnum(key)));
                }
            };
        }
    };
}
