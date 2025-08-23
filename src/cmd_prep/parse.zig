const Channel = @import("PrepRunner.zig").Channel;
const c = @import("gvca").c_helper.c;

pub fn task(channel: *Channel, commit_oid: c.git_oid, commit_seq: usize) void {
    _ = channel;
    _ = commit_oid;
    _ = commit_seq;
}
