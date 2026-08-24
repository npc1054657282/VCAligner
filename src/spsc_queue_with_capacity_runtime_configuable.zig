const std = @import("std");

const Error = error{};

pub fn SpscQueue(comptime T: type, comptime SequenceTypeOverride: ?type) type {
    _ = T;
    return struct {
        pub const Sequence = SequenceTypeOverride orelse u32;
        pub const CapLog2: type = std.math.Log2Int(std.meta.Int(.unsigned, @min(@bitSizeOf(Sequence), @bitSizeOf(usize))));
    };
}
