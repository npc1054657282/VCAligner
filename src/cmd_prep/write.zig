const Channel = @import("preprocess.zig").Channel;

pub fn task(channel: *Channel) void {
    var cache = channel.mpsc_queue_ref.initConsumerLocal();
    while (channel.claimConsume(&cache, null)) |lease| {
        const ticket, const parsed = lease;
        defer channel.releaseConsumedUnsafe(ticket);
        _ = parsed;
    } else |_| {}
}
