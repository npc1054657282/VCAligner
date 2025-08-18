//! 多生产者，单消费者的工作队列。
//! 实现为一个环形缓冲区，混合利用原子量与锁/条件量实现多线程安全。
//! 其中，原子量为多生产者的核心安全手段，关键部分无锁。锁/条件量用于反压通知机制。

const std = @import("std");
const options = @import("mpsc_queue_options");

pub const runtime_safety = switch (@import("builtin").mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};

// 生产者只关心一件事：哪些是consumer已经消费完了的。
// 消费者只关心一件事：自己即将声明的。
fn local_cache(comptime Sequence: type) type {
    return struct {
        const Producer = struct {
            consume_cursor_to_release: Sequence,
            unpublished_produce: if (runtime_safety) usize else void,
        };
        const Consumer = struct {
            consume_cursor_to_claim: Sequence,
            consume_cursor_to_invalidate: if (runtime_safety) Sequence else void,
            consume_cursor_to_release: if (runtime_safety) Sequence else void,
        };
    };
}

// 设置ticket.Produce与ticket.Consume两个本质相同的概念。
// 将它们隔离开可以阻止生产者调用消费者的api，以及阻止消费者调用生产者的api。
fn ticket(comptime Sequence: type) type {
    const ProducerLocal = local_cache(Sequence).Producer;
    const ConsumerLocal = local_cache(Sequence).Consumer;
    return struct {
        const Produce = struct {
            v: Sequence,
            cache: if (runtime_safety) *ProducerLocal else void,
        };
        const Consume: type = struct {
            v: Sequence,
            cache: if (runtime_safety) *ConsumerLocal else void,
        };
        const ProduceMultiple = struct {
            first_ticket: Sequence,
            count: usize,
            cache: if (runtime_safety) *ProducerLocal else void,
        };
    };
}

const MpscQueueError = error{
    MpscQueueUnreasonableCapacity,
    MpscQueueVacancyUnavailableForProducer,
    MpscQueueVacancyInsufficientForProducer,
    MpscQueueProductUnavailableForConsumer,
};

// 根据平台解析最适合的Sequence。允许高级使用者传入一个参数来自定义Sequence以重载解析而得的结果。
// u8，u16不安全。若配置这些类型的Sequence，使用者必须确认自己的需求以后，通过构建系统关闭警告配置。
fn ResolvedSequence(comptime SequenceTypeOverride: ?type) type {
    // 之所以写成这种用blk的有些繁琐的形式，只是为了更好地让zls分析出它返回的是个类型（写成分别return，zls不能立即正确高亮）
    return if (SequenceTypeOverride) |Override| blk: {
        switch (Override) {
            u8, u16 => if (options.enable_sequence_type_override_warning) @compileError(
                \\WARNING: Using a small Sequence type is unsafe. It is easy to lead to an ABA issue. 
                \\If you fully understand what you are doing, 
                \\To disable this warning, pass `.enable_sequence_type_override_warning = false` in the options.
                \\
            ),
            // 对于usize较小的平台，我们总体上信任usize足以在该平台下不易触发ABA现象，并允许用户对即使较小的usize进行重载。
            u32, u64, u128, usize => {},
            else => @compileError(
                \\`SequenceTypeOverride` must be an unsigned integer to allow atomic operations (extern structs can contain). 
                \\note: only integers with 0, 8, 16, 32, 64 and 128 bits are extern compatible
                \\
            ),
        }
        break :blk Override;
    } else blk: {
        if (@sizeOf(usize) >= 8) {
            break :blk usize;
        } else {
            // 在所有小于64位的系统上（如32位），
            // 为了绝对的环绕安全，我们默认牺牲一点性能，选择 u64。
            break :blk u64;
        }
    };
}

test ResolvedSequence {
    const T = ResolvedSequence(usize);
    try std.testing.expect(T == usize);
}

pub fn AnyMpscQueue(comptime T: type, comptime SequenceTypeOverride: ?type) type {
    const supported_capacity_log2_min = 5;
    const supported_capacity_log2_max = 20;
    const Dispatcher = comptime blk: {
        var union_fields: [supported_capacity_log2_max - supported_capacity_log2_min + 1]std.builtin.Type.UnionField = undefined;
        var enum_fields: [supported_capacity_log2_max - supported_capacity_log2_min + 1]std.builtin.Type.EnumField = undefined;
        for (supported_capacity_log2_min..supported_capacity_log2_max + 1, 0..) |capacity_log2, i| {
            const tag_name = std.fmt.comptimePrint("q{d}", .{1 << capacity_log2});
            const FieldType = *MpscQueue(T, capacity_log2, SequenceTypeOverride);
            const new_union_field: std.builtin.Type.UnionField = .{
                .name = tag_name,
                .type = FieldType,
                .alignment = @alignOf(FieldType),
            };
            const new_enum_field: std.builtin.Type.EnumField = .{
                .name = tag_name,
                .value = capacity_log2, // 将capacity_log2直接当做枚举标签值使用。
            };
            union_fields[i] = new_union_field;
            enum_fields[i] = new_enum_field;
        }
        const TagType = @Type(.{ .@"enum" = .{
            .tag_type = std.math.IntFittingRange(supported_capacity_log2_min, supported_capacity_log2_max),
            .fields = &enum_fields,
            .decls = &.{},
            .is_exhaustive = true,
        } });
        break :blk @Type(.{ .@"union" = .{
            .layout = .auto,
            .tag_type = TagType,
            .fields = &union_fields,
            .decls = &.{},
        } });
    };
    return struct {
        u: Dispatcher,
        pub const SourceGeneric = AnyMpscQueue;
        pub const ItemType = T;
        pub const Sequence = ResolvedSequence(SequenceTypeOverride);
        pub const ProduceTicket = ticket(Sequence).Produce;
        pub const ProduceTickets = ticket(Sequence).ProduceMultiple;
        pub const ConsumeTicket = ticket(Sequence).Consume;
        pub const ProducerLocal = local_cache(Sequence).Producer;
        pub const ConsumerLocal = local_cache(Sequence).Consumer;
        pub fn init(allocator: std.mem.Allocator, runtime_capacity_log2: u8) !@This() {
            var cap_log2 = runtime_capacity_log2;
            if (runtime_safety) {
                if (runtime_capacity_log2 < 5) {
                    std.log.warn("The capacity of the small mpsc queue will be automatically increased to 32.", .{});
                    cap_log2 = 5;
                }
            }
            switch (cap_log2) {
                inline supported_capacity_log2_min...supported_capacity_log2_max => |capacity_log2| {
                    const tag_name = std.fmt.comptimePrint("q{d}", .{1 << capacity_log2});
                    const ConcreteMpscQueue = @typeInfo(@FieldType(Dispatcher, tag_name)).pointer.child;
                    comptime std.debug.assert(ConcreteMpscQueue == MpscQueue(T, capacity_log2, SequenceTypeOverride));
                    const instance = try allocator.create(ConcreteMpscQueue);
                    instance.* = .init;
                    return .{
                        .u = @unionInit(Dispatcher, tag_name, instance),
                    };
                },
                else => return error.MpscQueueUnreasonableCapacity,
            }
        }
        pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
            switch (self.u) {
                inline else => |instance| {
                    allocator.destroy(instance);
                },
            }
        }
        pub fn getCapacity(self: @This()) usize {
            switch (self.u) {
                inline else => |instance| return instance.getCapacity(),
            }
        }
        pub fn initConsumerLocal(self: @This()) ConsumerLocal {
            switch (self.u) {
                inline else => |instance| return instance.initConsumerLocal(),
            }
        }
        pub fn initProducerLocal(self: @This()) ProducerLocal {
            switch (self.u) {
                inline else => |instance| return instance.initProducerLocal(),
            }
        }
        pub fn probeProduceVacancyForConsumer(self: *@This(), cache_consume_cursor_to_release: Sequence) usize {
            switch (self.u) {
                inline else => |instance| return instance.probeProduceVacancyForConsumer(cache_consume_cursor_to_release),
            }
        }
        pub fn claimProduce(self: @This(), cache: *ProducerLocal) !struct { ProduceTicket, *T } {
            switch (self.u) {
                inline else => |instance| return instance.claimProduce(cache),
            }
        }
        pub fn claimProduceMultiple(self: @This(), count: usize, cache: *ProducerLocal) !ProduceTickets {
            switch (self.u) {
                inline else => |instance| return instance.claimProduceMultiple(count, cache),
            }
        }
        pub fn claimProduceMultipleExact(self: @This(), count: usize, cache: *ProducerLocal) !ProduceTickets {
            switch (self.u) {
                inline else => |instance| return instance.claimProduceMultipleExact(count, cache),
            }
        }
        pub fn nextProduceTicket(self: @This(), tickets: *ProduceTickets) ?struct { ProduceTicket, *T } {
            switch (self.u) {
                inline else => |instance| return instance.nextProduceTicket(tickets),
            }
        }
        pub fn publishProducedUnsafe(self: @This(), produce_ticket: ProduceTicket) void {
            switch (self.u) {
                inline else => |instance| instance.publishProducedUnsafe(produce_ticket),
            }
        }
        pub fn publishProduced(self: @This(), produce_ticket: ProduceTicket, item_ref: **T) void {
            if (runtime_safety) {
                switch (self.u) {
                    inline else => |instance| instance.publishProduced(produce_ticket, item_ref),
                }
            } else {
                // 在非runtime_safety下，希望这么做可以有助于通过内联来降低实际所需的参数数量。
                self.publishProducedUnsafe(produce_ticket);
                item_ref.* = undefined;
            }
        }
        pub fn claimConsume(self: @This(), cache: *ConsumerLocal) !struct { ConsumeTicket, *T } {
            switch (self.u) {
                inline else => |instance| return instance.claimConsume(cache),
            }
        }
        pub fn releaseConsumedUnsafe(self: @This(), consume_ticket: ConsumeTicket) void {
            switch (self.u) {
                inline else => |instance| instance.releaseConsumedUnsafe(consume_ticket),
            }
        }
        pub fn releaseConsumed(self: @This(), consume_ticket: ConsumeTicket, item_ref: **T) void {
            if (runtime_safety) {
                switch (self.u) {
                    inline else => |instance| instance.releaseConsumed(consume_ticket, item_ref),
                }
            } else {
                // 在非runtime_safety下，希望这么做可以有助于通过内联来降低实际所需的参数数量。
                self.releaseConsumedUnsafe(consume_ticket);
                item_ref.* = undefined;
            }
        }
        pub fn invalidateConsumed(self: @This(), consume_ticket: ConsumeTicket, item_ref: **T) void {
            if (runtime_safety) {
                switch (self.u) {
                    inline else => |instance| instance.invalidateConsumed(consume_ticket, item_ref),
                }
            } else {
                // 在非runtime_safety下，希望这么做可以有助于通过内联来降低实际所需的参数数量。
                item_ref.* = undefined;
            }
        }
        pub fn releaseConsumedInvalidated(self: *@This(), consume_ticket: ConsumeTicket) void {
            switch (self.u) {
                inline else => |instance| instance.releaseConsumedInvalidated(consume_ticket),
            }
        }
    };
}

pub fn MpscQueue(comptime T: type, comptime capacity_log2: u8, comptime SequenceTypeOverride: ?type) type {
    std.debug.assert(capacity_log2 < 8 * @sizeOf(ResolvedSequence(SequenceTypeOverride)));
    if (options.enable_small_object_warning) {
        if (@sizeOf(T) <= (std.atomic.cache_line >> 1)) {
            const error_message = std.fmt.comptimePrint(
                \\WARNING: This mpsc queue is suitable for large objects that utilize cache lines effectively.
                \\The size of the object type '{s}' is {d} bytes.
                \\On the current target with a cache line size of {d} bytes, this is less than or
                \\equal to the recommended minimum of {d} bytes ({d} / 2).
                \\Using this queue for small objects may result in significant memory waste due to padding.
                \\To disable this warning, pass `.enable_small_object_warning = false` in the options.
            ,
                .{ @typeName(T), @sizeOf(T), std.atomic.cache_line, (std.atomic.cache_line >> 1), std.atomic.cache_line },
            );
            @compileError(error_message);
        }
    }
    return struct {
        buf: [capacity]Slot,
        produce_cursor_to_claim: std.atomic.Value(Sequence) align(std.atomic.cache_line),
        consume_cursor_to_release: std.atomic.Value(Sequence) align(std.atomic.cache_line),
        safety: SafetyChecks,
        pub const SourceGeneric = MpscQueue;
        pub const ItemType = T;
        pub const Sequence = ResolvedSequence(SequenceTypeOverride);
        pub const ProduceTicket = ticket(Sequence).Produce;
        pub const ProduceTickets = ticket(Sequence).ProduceMultiple;
        pub const ConsumeTicket = ticket(Sequence).Consume;
        pub const ProducerLocal = local_cache(Sequence).Producer;
        pub const ConsumerLocal = local_cache(Sequence).Consumer;
        // 对于编译期泛型Slot，目前zig不支持对它设定整体的对齐。因此，只能通过设定它的第一个元素的对齐方式来设定整个结构体的对齐方式。
        // 理论上，如果有内存重排优化导致item不再是第一个元素，将导致极大内存浪费，若需要确保避免这一点，需要设定为`extern struct`。
        // 但是，这会带来极大的对外兼容困难。因此，只能信任编译器不会做愚蠢的优化。
        const Slot = struct {
            item: T align(std.atomic.cache_line),
            // XXX: 另一种可能的实现是，available设计为写入值为ticket >> capacity_log2。
            // 消费者需要将`consumer_cursor >> capacity_log2`与available比较决定是否允许消费。
            // 这种实现可能对内存有更极致的压缩。在某些边缘场景，可以避免Slot浪费一个缓存行的大小。
            // 但考虑到绝大多数超过32字节的结构体的对齐往往是`usize`，
            // 而Sequence的大小大多也是`usize`，因此这么做能确实生效的情景存疑。而移位的开销稳定存在。
            available: std.atomic.Value(Sequence),
        };
        pub const init: @This() = .{
            .buf = @splat(.{ .item = undefined, .available = .init(~@as(Sequence, 0)) }),
            .produce_cursor_to_claim = .init(0),
            .consume_cursor_to_release = .init(0),
            .safety = .{},
        };
        const capacity = 1 << capacity_log2;
        const mask = capacity - 1;
        const SafetyChecks = if (runtime_safety) struct {
            consumer_local_cache_inited: std.atomic.Value(bool) align(std.atomic.cache_line) = .init(false),
        } else void;
        pub fn getCapacity(_: *@This()) usize {
            return capacity;
        }
        pub fn initConsumerLocal(self: *@This()) ConsumerLocal {
            if (runtime_safety) {
                const inited = self.safety.consumer_local_cache_inited.load(.monotonic);
                std.debug.assert(!inited);
                self.safety.consumer_local_cache_inited.store(true, .monotonic);
            }
            return .{
                .consume_cursor_to_claim = 0,
                .consume_cursor_to_invalidate = if (runtime_safety) 0 else {},
                .consume_cursor_to_release = if (runtime_safety) 0 else {},
            };
        }
        pub fn initProducerLocal(self: *@This()) ProducerLocal {
            return .{
                .consume_cursor_to_release = self.consume_cursor_to_release.load(.monotonic),
                .unpublished_produce = if (runtime_safety) 0 else {},
            };
        }
        fn probeProduceVacancy(cache_produce_cursor_to_claim: Sequence, cache_consume_cursor_to_release: Sequence) usize {
            // 由于produce_cursor与consume_cursor都是缓存值，且consume_cursor一般比produce_cursor旧。
            // 因此，可能存在差距过大，结果为负数的情况，此时判定为余量为0，故采用饱和减法。
            // 在默认的Sequence长度u64下，即使produce_cursor每秒可以增加100亿，也需要50年才能环绕一周。
            // 这意味着，除非某线程距离上次缓存consume_cursor过了50年才开始下一次操作，否则此处不可能有ABA现象。
            return capacity -| (cache_produce_cursor_to_claim -% cache_consume_cursor_to_release);
        }
        pub fn probeProduceVacancyForConsumer(self: *@This(), cache_consume_cursor_to_release: Sequence) usize {
            const cache_produce_cursor_to_claim = self.produce_cursor_to_claim.load(.acquire);
            return probeProduceVacancy(cache_produce_cursor_to_claim, cache_consume_cursor_to_release);
        }
        // 三个API，分别代表1.申请一次生产；2.申请多次生产，但如果空间不足则依然成功并申请剩余空间；
        // 3.申请多次生产，且必须确保一次性申请的内容是相邻的，如果空间不足则申请失败。
        // XXX: 一种实现是创建统一的`claimProduceInner`，这三个API是对该内部函数的不同参数的包装。
        // 但是，这种实现很可能无法被内联，导致了一些额外开销。这里的三个API的实现较为重复，以确保不会有额外的调用开销。
        pub fn claimProduce(self: *@This(), cache: *ProducerLocal) !struct { ProduceTicket, *T } {
            // 由于`produce_cursor`会进行后续cas比较，此处的检查只需要弱序即可。
            var cache_produce_cursor = self.produce_cursor_to_claim.load(.monotonic);
            var cas_result: ?Sequence = undefined;
            var new_produce_cursor: Sequence = undefined;
            while (do_blk: {
                // 缓存的`consume_cursor`与新获取的`produce_cursor`判定非满，则一定非满。
                // 否则，读取`consume_cursor`，如果仍然判定满，才是满。
                if (probeProduceVacancy(cache_produce_cursor, cache.consume_cursor_to_release) == 0) {
                    // 唯一与consume_cursor同步手段，`acquire`序必须。
                    cache.consume_cursor_to_release = self.consume_cursor_to_release.load(.acquire);
                    if (probeProduceVacancy(cache_produce_cursor, cache.consume_cursor_to_release) == 0) return error.MpscQueueVacancyUnavailableForProducer;
                }
                new_produce_cursor = cache_produce_cursor +% 1;
                // 此处内存序`acquire`即可，claim阶段没有需要发布给consumer的数据。
                // ABA安全依赖于`Sequence`长度，参见`probeProduceVacancy`。
                cas_result = self.produce_cursor_to_claim.cmpxchgWeak(cache_produce_cursor, new_produce_cursor, .acquire, .monotonic);
                break :do_blk cas_result != null;
            }) {
                cache_produce_cursor = cas_result.?;
            }
            const produce_ticket: ProduceTicket = .{
                .v = cache_produce_cursor,
                .cache = if (runtime_safety) cache else {},
            };
            if (runtime_safety) cache.unpublished_produce += 1;
            return .{ produce_ticket, &self.buf[produce_ticket.v & mask].item };
        }
        // 返回一个`Tickets`，需要基于`Tickets`迭代地获取一个`Ticket`与一个item。每个`Ticket`需要分别publish
        // 如果剩余空间不够，则申请剩余所有空间用于生产。
        pub fn claimProduceMultiple(self: *@This(), count: usize, cache: *ProducerLocal) !ProduceTickets {
            std.debug.assert(count != 0);
            var cache_produce_cursor = self.produce_cursor_to_claim.load(.monotonic);
            var cas_result: ?Sequence = undefined;
            var new_produce_cursor: Sequence = undefined;
            var actual_count: usize = undefined;
            while (do_blk: {
                // 先检查最乐观情况：基于消费者的旧缓存，也能确认足以承载所有请求生产量的情况。
                if (probeProduceVacancy(cache_produce_cursor, cache.consume_cursor_to_release) < count) {
                    // 若不是最乐观情况，更新消费者旧缓存，重新检查余量。
                    cache.consume_cursor_to_release = self.consume_cursor_to_release.load(.acquire);
                    const produce_avail = probeProduceVacancy(cache_produce_cursor, cache.consume_cursor_to_release);
                    actual_count = if (produce_avail >= count) count else if (produce_avail == 0) return error.MpscQueueVacancyUnavailableForProducer else produce_avail;
                } else actual_count = count;
                new_produce_cursor = cache_produce_cursor +% actual_count;
                // ABA安全依赖于`Sequence`长度，参见`probeProduceVacancy`。
                cas_result = self.produce_cursor_to_claim.cmpxchgWeak(cache_produce_cursor, new_produce_cursor, .acquire, .monotonic);
                break :do_blk cas_result != null;
            }) {
                cache_produce_cursor = cas_result.?;
            }
            if (runtime_safety) cache.unpublished_produce += actual_count;
            return .{
                .first_ticket = cache_produce_cursor,
                .count = actual_count,
                .cache = if (runtime_safety) cache else {},
            };
        }
        // 如果剩余空间不够，直接失败。
        pub fn claimProduceMultipleExact(self: *@This(), count: usize, cache: *ProducerLocal) !ProduceTickets {
            std.debug.assert(count != 0);
            var cache_produce_cursor = self.produce_cursor_to_claim.load(.monotonic);
            var cas_result: ?Sequence = undefined;
            var new_produce_cursor: Sequence = undefined;
            while (do_blk: {
                // 先检查最乐观情况：基于消费者的旧缓存，也能确认足以承载所有请求生产量的情况。
                if (probeProduceVacancy(cache_produce_cursor, cache.consume_cursor_to_release) < count) {
                    // 若不是最乐观情况，更新消费者旧缓存，重新检查余量。
                    cache.consume_cursor_to_release = self.consume_cursor_to_release.load(.acquire);
                    const produce_avail = probeProduceVacancy(cache_produce_cursor, cache.consume_cursor_to_release);
                    if (produce_avail == 0) return error.MpscQueueVacancyUnavailableForProducer;
                    if (produce_avail < count) return error.MpscQueueVacancyInsufficientForProducer;
                }
                new_produce_cursor = cache_produce_cursor +% count;
                // ABA安全依赖于`Sequence`长度，参见`probeProduceVacancy`。
                cas_result = self.produce_cursor_to_claim.cmpxchgWeak(cache_produce_cursor, new_produce_cursor, .acquire, .monotonic);
                break :do_blk cas_result != null;
            }) {
                cache_produce_cursor = cas_result.?;
            }
            if (runtime_safety) cache.unpublished_produce += count;
            return .{
                .first_ticket = cache_produce_cursor,
                .count = count,
                .cache = if (runtime_safety) cache else {},
            };
        }
        pub fn nextProduceTicket(self: *@This(), tickets: *ProduceTickets) ?struct { ProduceTicket, *T } {
            if (tickets.count == 0) return null;
            const produce_ticket: ProduceTicket = .{
                .v = tickets.first_ticket,
                .cache = if (runtime_safety) tickets.cache else {},
            };
            tickets.count -= 1;
            tickets.first_ticket +%= 1;
            return .{ produce_ticket, &self.buf[produce_ticket.v & mask].item };
        }
        pub fn publishProducedUnsafe(self: *@This(), produce_ticket: ProduceTicket) void {
            if (runtime_safety) produce_ticket.cache.unpublished_produce -= 1;
            self.buf[produce_ticket.v & mask].available.store(produce_ticket.v, .release);
        }
        pub fn publishProduced(self: *@This(), produce_ticket: ProduceTicket, item_ref: **T) void {
            if (runtime_safety) {
                // 在`runtime_safety`下，确保不会重复`publish`同一个ticket。
                const old_available = self.buf[produce_ticket.v & mask].available.load(.monotonic);
                std.debug.assert((produce_ticket.v >> capacity_log2) == ((old_available >> capacity_log2) +% 1));
                // 确保毒化的`item_ref`与ticket对应。
                std.debug.assert(&self.buf[produce_ticket.v & mask].item == item_ref.*);
            }
            self.publishProducedUnsafe(produce_ticket);
            item_ref.* = undefined;
        }
        pub fn claimConsume(self: *@This(), cache: *ConsumerLocal) !struct { ConsumeTicket, *T } {
            const consume_ticket: ConsumeTicket = .{
                .v = cache.consume_cursor_to_claim,
                .cache = if (runtime_safety) cache else {},
            };
            const available: Sequence = self.buf[consume_ticket.v & mask].available.load(.acquire);
            if (available != consume_ticket.v) return error.MpscQueueProductUnavailableForConsumer;
            cache.consume_cursor_to_claim +%= 1;
            return .{ consume_ticket, &self.buf[consume_ticket.v & mask].item };
        }
        pub fn releaseConsumedUnsafe(self: *@This(), consume_ticket: ConsumeTicket) void {
            if (runtime_safety) {
                consume_ticket.cache.consume_cursor_to_invalidate = consume_ticket.v +% 1;
                consume_ticket.cache.consume_cursor_to_release = consume_ticket.v +% 1;
            }
            self.consume_cursor_to_release.store(consume_ticket.v +% 1, .release);
        }
        pub fn releaseConsumed(self: *@This(), consume_ticket: ConsumeTicket, item_ref: **T) void {
            if (runtime_safety) {
                std.debug.assert(consume_ticket.cache.consume_cursor_to_invalidate == consume_ticket.v);
                std.debug.assert(&self.buf[consume_ticket.v & mask].item == item_ref.*);
            }
            releaseConsumedUnsafe(self, consume_ticket);
            item_ref.* = undefined;
        }
        pub fn invalidateConsumed(self: *@This(), consume_ticket: ConsumeTicket, item_ref: **T) void {
            if (runtime_safety) {
                std.debug.assert(consume_ticket.cache.consume_cursor_to_invalidate == consume_ticket.v);
                std.debug.assert(&self.buf[consume_ticket.v & mask].item == item_ref.*);
                self.safety.consume_cursor_to_invalidate +%= 1;
            }
            item_ref.* = undefined;
        }
        pub fn releaseConsumedInvalidated(self: *@This(), consume_ticket: ConsumeTicket) void {
            if (runtime_safety) {
                std.debug.assert(consume_ticket.cache.consume_cursor_to_invalidate == consume_ticket.v +% 1);
            }
            releaseConsumedUnsafe(self, consume_ticket);
        }
    };
}

test "Sequence name" {
    const capacity_log2 = 18;
    const Sequence = switch (capacity_log2) {
        0...7 => u8,
        8...15 => u16,
        16...31 => u32,
        32...63 => u64,
        64...127 => u128,
        else => usize,
    };
    try std.testing.expect(std.mem.eql(u8, @typeName(Sequence), "u32"));
    try std.testing.expect(std.mem.eql(u8, @typeName(usize), "usize"));
}
