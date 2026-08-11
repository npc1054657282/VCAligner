const std = @import("std");
const vcaligner = @import("vcaligner");
const c_helper = vcaligner.c_helper;
const c = c_helper.c;
const CompactionStrategy = @import("PrepRunner.zig").CompactionStrategy;
const RocksdbPath = @import("preprocess.zig").RocksdbPath;

const checkpoint_path_suffix = ".checkpoint";

pub const State = struct {
    maybe_valid_handles: union(enum) {
        valid: Handles,
        invalid: void,
    },
    maybe_checkpoint_path: union(enum) {
        need: [:0]u8,
        neednt: void,
    },
    pub fn init(
        self: *State,
        mode: @import("PrepRunner.zig").Mode,
        n_rocksdbjobs: c_int,
        compaction_strategy: CompactionStrategy,
        compression: bool,
        cf_max_write_buffer_number: c_int,
        rocksdb_path: [:0]const u8,
        allocator: *std.mem.Allocator,
        last_diag: *vcaligner.diag.Diagnostic,
    ) !void {
        self = .{ .maybe_handles = .{ .valid = undefined }, .maybe_checkpoint_path = undefined };
        try self.valid.initForWrite(mode, n_rocksdbjobs, compaction_strategy, compression, cf_max_write_buffer_number, rocksdb_path, last_diag);
        errdefer self.valid.deinit();
        self.maybe_checkpoint_path = switch (mode) {
            .full => .neednt,
            .incremental => checkpoint: {
                const checkpoint_path = try std.fmt.allocPrintSentinel(allocator, "{s}{s}", .{ rocksdb_path, checkpoint_path_suffix }, 0);
                errdefer allocator.free(checkpoint_path);
                // TODO: 增加创建checkpoint逻辑。
                break :checkpoint .{ .need = checkpoint_path };
            },
        };
    }
    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        switch (self.maybe_valid_handles) {
            .valid => |*handles| {
                // TODO: 增加移除checkpoint逻辑。
                remove_checkpoint: {
                    break :remove_checkpoint;
                }
                handles.deinit();
            },
            .invalid => {},
        }
        switch (self.maybe_checkpoint_path) {
            .need => |checkpoint_path| {
                allocator.free(checkpoint_path);
            },
            .neednt => {},
        }
    }
    pub fn deinitOnErr(self: *State, allocator: std.mem.Allocator) void {
        switch (self.maybe_valid_handles) {
            .valid => |*handles| {
                handles.deinit();
                self.maybe_valid_handles = .invalid;
            },
            .invalid => {},
        }
        switch (self.maybe_checkpoint_path) {
            .need => |checkpoint_path| {
                allocator.free(checkpoint_path);
                self.maybe_checkpoint_path = .neednt;
            },
            .neednt => {},
        }
    }
    // 假定`self`的`maybe_handles`是`valid`的情境下允许调用。仅用于全量写入后的延迟全量compaction。
    pub fn reopenAndWaitForFullCompaction(
        self: *State,
        n_rocksdbjobs: c_int,
        compression: bool,
        rocksdb_path: [:0]const u8,
        last_diag: *vcaligner.diag.Diagnostic,
    ) !void {
        try self.reopenForFullCompaction(
            n_rocksdbjobs,
            compression,
            rocksdb_path,
            last_diag,
        );
        const compact_options = c.rocksdb_compactoptions_create();
        defer c.rocksdb_compactoptions_destroy(compact_options);
        // 遍历所有的累积写入的列族进行压缩
        const cumulative_storage: Cumulative = .fromFullStorage(&self.valid);
        for (cumulative_storage.cf_handles.values) |cf_handle| {
            c.rocksdb_compact_range_cf_opt(
                self.valid.db,
                cf_handle,
                compact_options,
                // null 代表从头开始
                null,
                0,
                // null 代表一直到结尾
                null,
                0,
            );
        }
        // NOTE: `rocksdb_compact_range_cf_opt`是同步的，无需使用`rocksdb_wait_for_compact`等待。
    }
    fn reopenForFullCompaction(
        self: *State,
        n_rocksdbjobs: c_int,
        compression: bool,
        rocksdb_path: [:0]const u8,
        last_diag: *vcaligner.diag.Diagnostic,
    ) !void {
        self.maybe_valid_handles.valid.deinit();
        errdefer self.maybe_valid_handles = .invalid;
        try self.maybe_valid_handles.valid.initForManualCompaction(n_rocksdbjobs, compression, rocksdb_path, last_diag);
    }
};

pub const Handles = struct {
    db: *c.rocksdb_t,
    cf_handles: std.enums.EnumArray(vcaligner.rocksdb_custom.CollumFamily, ?*c.rocksdb_column_family_handle_t),
    fn initForWrite(
        self: *Handles,
        mode: @import("PrepRunner.zig").Mode,
        n_rocksdbjobs: c_int,
        compaction_strategy: CompactionStrategy,
        compression: bool,
        cf_max_write_buffer_number: c_int,
        rocksdb_path: []const u8,
        last_diag: *vcaligner.diag.Diagnostic,
    ) !void {
        const db_options = blk: {
            const db_options = c.rocksdb_options_create().?;
            c.rocksdb_options_set_create_if_missing(db_options, switch (mode) {
                .full => 1,
                .incremental => 0,
            });
            c.rocksdb_options_set_error_if_exists(db_options, switch (mode) {
                .full => 1,
                .incremental => 0,
            });
            c.rocksdb_options_increase_parallelism(db_options, n_rocksdbjobs);
            // 仅单线程写入，获取一点微小的性能提升。
            // NOTE: `inplace_update_support`无用，不予配置。
            c.rocksdb_options_set_allow_concurrent_memtable_write(db_options, 0);
            // NOTE: 默认无限制地打开文件，由于实际打开的文件数量有好几千，将导致无限制的内存提交，最终导致over commit。必须限制
            c.rocksdb_options_set_max_open_files(db_options, 1024);
            // 总体而言不论全量还是增量，待写入内容都几乎是只写不读的，操作系统的页缓存基本没有意义，如果有自动compaction，反而容易缓存污染，总是启用direct IO。
            // 在windows测试时，发现有文件删除延迟导致磁盘耗尽的现象，据说`direct_io`对windows支持不好，不确定`direct_io`是否有影响。
            // 目前主要考虑linux平台，不将windows作为主要支持目标。
            c.rocksdb_options_set_use_direct_io_for_flush_and_compaction(db_options, 1);
            // 可能因文件删除延迟导致磁盘耗尽现象。虽然我看文档说compaction会自动删除，不受此配置影响，但是观测的删除依然延迟。增加每分钟一次的删除废弃文件。
            // 增加以后仍然未解决。后得知应该是删除线程的异步性导致被compaction的文件未能被及时删除，因为删除的线程应该始终未能被执行。
            // 而flush线程才是被优先执行的。
            c.rocksdb_options_set_delete_obsolete_files_period_micros(db_options, 30 * 1000000);
            // 一种可能的方案是增加SstFileManager检测磁盘限制。但实践中磁盘耗尽现象罕见，不再进一步考虑此问题。

            if (compaction_strategy == .manual_delayed) {
                // 手动延迟全量compaction，即写入时不compaction，即采用prepare for bulk load配置。
                // 此配置是一个混合配置：部分影响数据库行为，部分影响默认列族的行为。此处我们采用其影响数据库行为的部分。
                // 这个行为会设置`flush`线程上限为4。这里还会酌情进一步增加上限。不用担心`flush`线程数影响parser等其他线程，因为这是I/O密集线程，不怎么影响计算线程。
                c.rocksdb_options_prepare_for_bulk_load(db_options);
                c.rocksdb_options_set_max_background_flushes(db_options, n_rocksdbjobs);
            }
            // NOTE：当options已经被用于打开rocksdb以后，rocksdb内部有此配置的拷贝，对options的直接修改不会影响rocksdb。
            // 虽然后续可以用`rocksdb_set_options`和`rocksdb_set_options_cf`中途修改各默认列族的行为。
            // 但是，C API不支持`SetDBOptions`，也就是修改数据库本体的操作。后续必须关闭数据库再重新打开。
            break :blk db_options;
        };
        defer c.rocksdb_options_destroy(db_options);

        const normal_cf_options = blk: {
            const cf_options = c.rocksdb_options_create().?;
            applyHeavyWriteOptimizationsOnCfOptions(cf_options, compression, compaction_strategy, cf_max_write_buffer_number);
            break :blk cf_options;
        };
        defer c.rocksdb_options_destroy(normal_cf_options);
        var all_cf_options: std.enums.EnumArray(vcaligner.rocksdb_custom.CollumFamily, ?*const c.rocksdb_options_t) = .init(.{
            .bpi_ci = undefined,
            .pi_p = normal_cf_options,
            .b_pi_bpi = undefined,
            .ci_c = normal_cf_options,
            .pr_pi = undefined,
        });
        all_cf_options.set(.bpi_ci, blk: {
            const cf_options = c.rocksdb_options_create().?;
            applyHeavyWriteOptimizationsOnCfOptions(cf_options, compression, compaction_strategy, cf_max_write_buffer_number);
            // 一定要小心，此处神坑！slicetransform和mergeoperator进入options时都会变成shared ptr并且移交所有权！
            // 千万不要调用C API提供的`rocksdb_slicetransform_destroy`和`rocksdb_mergeoperator_destroy`！
            // 默认列族以blob-path-id为前缀。不使用布隆过滤器，因为后续使用数据库的时候基本没有需要检查无效的key的情况。
            c.rocksdb_options_set_prefix_extractor(cf_options, c.rocksdb_slicetransform_create_fixed_prefix(@sizeOf(vcaligner.rocksdb_custom.BlobPathSeq)));
            break :blk cf_options;
        });
        defer c.rocksdb_options_destroy(all_cf_options.get(.bpi_ci));
        all_cf_options.set(.b_pi_bpi, blk: {
            const cf_options = c.rocksdb_options_create().?;
            applyHeavyWriteOptimizationsOnCfOptions(cf_options, compression, compaction_strategy, cf_max_write_buffer_number);
            c.rocksdb_options_set_prefix_extractor(cf_options, c.rocksdb_slicetransform_create_fixed_prefix(@sizeOf(c.git_oid)));
            break :blk cf_options;
        });
        defer c.rocksdb_options_destroy(all_cf_options.get(.b_pi_bpi));
        all_cf_options.set(.pr_pi, blk: {
            const cf_options = c.rocksdb_options_create().?;
            // 如果其他列族使用自动compaction，pr2pi依然需要在最后全量手动compaction。
            // 如果其他列族使用延迟全量compaction，预计整个数据库将要重新被打开，这里对pr2pi怎么配置都无所谓。
            applyFullCompactionOptimizationsOnCfOptions(cf_options, compression);
            break :blk cf_options;
        });
        defer c.rocksdb_options_destroy(all_cf_options.get(.pr_pi));
        self.db = blk: {
            var err_cstr: ?[*:0]u8 = null;
            const db = c.rocksdb_open_column_families(
                db_options,
                rocksdb_path,
                vcaligner.rocksdb_custom.cf_names.values.len,
                @ptrCast(&vcaligner.rocksdb_custom.cf_names.values),
                &all_cf_options.values,
                &self.cf_handles.values,
                @ptrCast(&err_cstr),
            );
            try c_helper.checkRocksdbErr(err_cstr, @src(), last_diag);
            break :blk db.?;
        };
    }
    fn initForManualCompaction(
        self: *Handles,
        n_rocksdbjobs: c_int,
        compression: bool,
        rocksdb_path: [:0]const u8,
        last_diag: *vcaligner.diag.Diagnostic,
    ) !void {
        const db_options = blk: {
            const db_options = c.rocksdb_options_create().?;
            c.rocksdb_options_set_create_if_missing(db_options, 0);
            c.rocksdb_options_set_error_if_exists(db_options, 0);
            c.rocksdb_options_increase_parallelism(db_options, n_rocksdbjobs);
            c.rocksdb_options_set_max_background_compactions(db_options, n_rocksdbjobs);
            c.rocksdb_options_set_max_background_flushes(db_options, 1);
            c.rocksdb_options_set_max_open_files(db_options, 1024);
            break :blk db_options;
        };
        defer c.rocksdb_options_destroy(db_options);
        // 非默认列族（除b_pi_bpi外）的选项
        const normal_cf_options = blk: {
            const cf_options = c.rocksdb_options_create().?;
            applyFullCompactionOptimizationsOnCfOptions(cf_options, compression);
            break :blk cf_options;
        };
        defer c.rocksdb_options_destroy(normal_cf_options);
        var all_cf_options: std.enums.EnumArray(vcaligner.rocksdb_custom.CollumFamily, ?*const c.rocksdb_options_t) = .init(.{
            .bpi_ci = undefined,
            .pi_p = normal_cf_options,
            .b_pi_bpi = undefined,
            .ci_c = normal_cf_options,
            .pr_pi = normal_cf_options,
        });
        all_cf_options.set(.bpi_ci, blk: {
            const cf_options = c.rocksdb_options_create().?;
            applyFullCompactionOptimizationsOnCfOptions(cf_options, compression);
            c.rocksdb_options_set_prefix_extractor(cf_options, c.rocksdb_slicetransform_create_fixed_prefix(@sizeOf(vcaligner.rocksdb_custom.BlobPathSeq)));
            break :blk cf_options;
        });
        defer c.rocksdb_options_destroy(all_cf_options.get(.bpi_ci));
        all_cf_options.set(.b_pi_bpi, blk: {
            const cf_options = c.rocksdb_options_create().?;
            applyFullCompactionOptimizationsOnCfOptions(cf_options, compression);
            c.rocksdb_options_set_prefix_extractor(cf_options, c.rocksdb_slicetransform_create_fixed_prefix(@sizeOf(c.git_oid)));
            break :blk cf_options;
        });
        defer c.rocksdb_options_destroy(all_cf_options.get(.b_pi_bpi));
        self.db = blk: {
            var err_cstr: ?[*:0]u8 = null;
            const new_db = c.rocksdb_open_column_families(
                db_options,
                rocksdb_path,
                vcaligner.rocksdb_custom.cf_names.values.len,
                @ptrCast(vcaligner.rocksdb_custom.cf_names.values),
                &all_cf_options.values,
                &self.cf_handles,
                @ptrCast(&err_cstr),
            );
            try c_helper.checkRocksdbErr(err_cstr, @src(), last_diag);
            break :blk new_db.?;
        };
    }
    fn deinit(self: *Handles) void {
        var iter = std.mem.reverseIterator((&self.cf_handles.values)[0..]);
        while (iter.next()) |cf_handle| {
            c.rocksdb_column_family_handle_destroy(cf_handle);
        }
        c.rocksdb_close(self.db);
        self.* = undefined;
    }
};

fn applyHeavyWriteOptimizationsOnCfOptions(
    cf_options: *c.rocksdb_options_t,
    compression: bool,
    compaction_strategy: CompactionStrategy,
    cf_max_write_buffer_number: c_int,
) void {
    if (compression) {
        // 关于压缩：原则上compaction阶段的压缩才影响最终大小，而写入阶段的压缩只影响中间文件大小而不影响最终大小。
        // 但是，在对postgresql的测试中，如果compaction阶段都不压缩，而只检验写入阶段的压缩，发现写入阶段压缩比不压缩反而快30秒左右（13分50秒与14分36秒的区别）
        // 这说明中间文件的大小变小实际上由于降低了I/O量，导致中间过程的压缩也反而对性能有益而非有害。
        c.rocksdb_options_set_compression(cf_options, c.rocksdb_lz4_compression);
    }
    sw: switch (compaction_strategy) {
        .manual_delayed => {
            // 此配置是一个混合配置：部分影响数据库行为，部分影响默认列族的行为。此处我们采用其影响列族行为的部分。
            // FAQ说这个函数会使用vector memtable。如果是这样的话，对我这种乱序写入的场景就不适合了。
            // 但是，所幸的是，看了[源码](https://github.com/facebook/rocksdb/blob/a34683bf543cc3eb151d08eeac00791862acd4d6/options/options.cc#L478-L519)
            // 实际没有修改memtable使用类型的行为，仅仅是全部写入L0以及禁止自动压缩。这些行为都是我需要的，可以放心使用。
            c.rocksdb_options_prepare_for_bulk_load(cf_options);
        },
        .auto_with_trigger => |compaction_trigger| {
            // 自动compaction，但配置了触发器
            c.rocksdb_options_set_level0_file_num_compaction_trigger(cf_options, compaction_trigger);
            c.rocksdb_options_set_level0_slowdown_writes_trigger(cf_options, compaction_trigger * 2);
            c.rocksdb_options_set_level0_stop_writes_trigger(cf_options, compaction_trigger * 4);
            // 其余配置和自动触发器相同。
            continue :sw .auto_default;
        },
        .auto_default => {
            // 自动compaction。下面的配置部分抄自prepare for bulk load内部实现，适用于大量数据写入。
            // 但不要像prepare for bulk load那样减少compaction层级，以及修改最大compation大小。
            // 各列族的最大write buffer number将在后文通过参数配置。
            c.rocksdb_options_set_min_write_buffer_number_to_merge(cf_options, 1);
            c.rocksdb_options_set_target_file_size_base(cf_options, 256 * 1024 * 1024);
            // flush和compaction的线程分配交给前面的`rocksdb_options_increase_parallelism`自动进行。
        },
    }
    // 增加`write_buffer_size`。目前默认的64MB可能导致多个小sst文件，增大单个sst文件的大小，降低文件数量，以避免文件打开与关闭开销。
    c.rocksdb_options_set_write_buffer_size(cf_options, 256 * 1024 * 1024);
    c.rocksdb_options_set_max_write_buffer_number(cf_options, cf_max_write_buffer_number);
}

fn applyFullCompactionOptimizationsOnCfOptions(
    options: *c.rocksdb_options_t,
    compression: bool,
) void {
    // 依旧禁用自动compaction。我们使用手动compaction，避免撞车。
    c.rocksdb_options_set_disable_auto_compactions(options, 1);
    // 手动 compaction 的最大字节数依然应为极大值。全量手动compaction不应当限制compaction的输入规模。
    c.rocksdb_options_set_max_compaction_bytes(options, 1 << 60);
    c.rocksdb_options_set_target_file_size_base(options, 256 * 1024 * 1024);
    if (compression) {
        c.rocksdb_options_set_compression(options, c.rocksdb_lz4_compression);
    }
}

pub const Cumulative = struct {
    db: *c.rocksdb_t,
    cf_handles: std.enums.EnumArray(enum(std.meta.Tag(vcaligner.rocksdb_custom.CollumFamily)) {
        bpi_ci = @intFromEnum(vcaligner.rocksdb_custom.CollumFamily.bpi_ci),
        pi_p = @intFromEnum(vcaligner.rocksdb_custom.CollumFamily.pi_p),
        b_pi_bpi = @intFromEnum(vcaligner.rocksdb_custom.CollumFamily.b_pi_bpi),
        ci_c = @intFromEnum(vcaligner.rocksdb_custom.CollumFamily.ci_c),
    }, ?*c.rocksdb_column_family_handle_t),
    pub fn fromFullStorage(storage: *Handles) Cumulative {
        return .{ .db = storage.db, .cf_handles = .init(.{
            .bpi_ci = storage.cf_handles.get(.bpi_ci),
            .pi_p = storage.cf_handles.get(.pi_p),
            .b_pi_bpi = storage.cf_handles.get(.b_pi_bpi),
            .ci_c = storage.cf_handles.get(.ci_c),
        }) };
    }
};
