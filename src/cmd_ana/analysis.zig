const std = @import("std");
const gvca = @import("gvca");
const AnaRunner = @import("AnaRunner.zig");
const diag = gvca.diag;

pub fn analysis(ctx: *AnaRunner, allocator: std.mem.Allocator, last_diag: *diag.Diagnostic) !void {
    _ = ctx;
    _ = allocator;
    _ = last_diag;
}

// 第一步：读取pr2pi列族和pi2p列族，获得一个pr2p的列表。
// 第二步：遍历pr2p列表，然后寻找release_path中是否存在对应路径。
// 第三步：找到对应路径的文件，若存在，将release_path下的对应文件进行hash。
// 第四步：读取default，根据path-blob对，获得一个commit range列表。
// 第五步：将新获得的commit range列表与先前的所有commit range列表寻找交集。如果全部没有交集，我们现在有新的commit range列表了。
