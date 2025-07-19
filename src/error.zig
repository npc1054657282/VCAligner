const std = @import("std");
const c = @import("c.zig").c;

// TODO: 根据目前zig社区的[issue](https://github.com/ziglang/zig/issues/24028)，以及被否决的[pr](https://github.com/ziglang/zig/pull/19092)
// 这似乎传递出社区并不鼓励errorset功能。对于我目前的错误处理情况，可能更被鼓励的实践是，只设计Libgit2Error一个上抛错误,
// 而把具体错误码保存在此上下文里。这其实对我目前的设计是一种简化，因为我本以为具体化错误，并利用错误集分析它们是一种更好的实践。
// 不论如何，在得到明确的结论前，我会继续当前的实践。

/// 本模块记录各api抛出错误时可能携带的上下文诊断信息集合通用结构。
/// 本模块被设计为一个不含tag的普通union，并且不提供分派api。这是因为本模块的逻辑本质上是由错误码驱动的，而非其自身标签驱动。
/// 但未来仍保留设计为tagged union的可能性，这种设计有可能利于显式的断言校验。但不使用tag仍可能通过非法行为来检测，这里的tag依旧是一个冗余。
/// 一种可能的设计是将错误转化为全局整数以定义enum tag的值。但这种设计不符合现实要求：一个LastError标签和具体的错误码可能是一对多的关系。
/// 本模块的所有指针不得持有内存！目前期待的LastError的最大尺寸应当很小，所以使用它时依赖值拷贝传递。
pub const LastError = union {
    libgit2: ?*const c.git_error,
    unknown_c_error: c_int, // 未知的c错误码，保存错误码本身。
    // 激活一个标签。
    pub fn activate(self: *LastError, field_name: []const u8) *LastError {
        self.* = @unionInit(LastError, field_name, undefined);
        return self;
    }
};

pub fn inErrorSet(comptime err: anyerror, comptime Err: type) bool {
    return @hasField(std.meta.FieldEnum(Err), @errorName(err));
}
