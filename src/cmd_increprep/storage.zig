const std = @import("std");
const vcaligner = @import("vcaligner");
const c_helper = vcaligner.c_helper;
const c = c_helper.c;
const CompactionStrategy = @import("PrepRunner.zig").CompactionStrategy;
const RecoveryPathConfView = @import("preprocess.zig").RecoveryPathConf.View;
pub const State = union(enum) {
    valid: Handles,
    invalid: void,
    pub fn init(
        self: *State,
        mode: @import("PrepRunner.zig").Mode,
        n_rocksdbjobs: c_int,
        compaction_strategy: CompactionStrategy,
        compression: bool,
        cf_max_write_buffer_number: c_int,
        rocksdb_path: [:0]const u8,
        recovery_path_conf: RecoveryPathConfView,
        last_diag: *vcaligner.diag.Diagnostic,
    ) !void {
        // 全量模式创建rocksdb_output的父目录。这是因为rocksdb没有自动创建父目录的能力。
        if (mode == .full) make_parent_dir: {
            // NOTE：父目录解析为`null`存在一个合法可能：`rocksdb_output`只有名字。此时父目录解析为`null`意味着父目录为当前目录。
            // 其它情况下解析为`null`的情况，不论是`rocksdb_output`是当前目录，或者是一个盘符都是非法的。
            // 这种情况将在`rocksdb`创建数据库的时候报告错误，因此此处不再检查。
            const maybe_parent_dir: ?[]const u8 = std.fs.path.dirname(rocksdb_path);
            if (maybe_parent_dir) |parent_dir| {
                const cwd = std.fs.cwd();
                cwd.access(parent_dir, .{}) catch |access_err| {
                    switch (access_err) {
                        error.FileNotFound => cwd.makePath(parent_dir) catch |mkdir_err| {
                            switch (mkdir_err) {
                                // 考虑多进程竞争场景，可能存在同进程已经创建目录的情形。此时是安全的。
                                error.PathAlreadyExists => {},
                                else => {
                                    std.log.err("make dir {s} error: {s}", .{ parent_dir, @errorName(mkdir_err) });
                                    return mkdir_err;
                                },
                            }
                        },
                        else => return access_err,
                    }
                };
            }
            break :make_parent_dir;
        }
        self.* = .{ .valid = undefined };
        try self.valid.initForWrite(mode, n_rocksdbjobs, compaction_strategy, compression, cf_max_write_buffer_number, rocksdb_path, last_diag);
        errdefer self.valid.deinit();
        switch (recovery_path_conf) {
            .disabled => {},
            .enabled => |path| {
                var err_cstr: ?[*:0]u8 = null;
                const checkpoint_object = c.rocksdb_checkpoint_object_create(self.valid.db, @ptrCast(&err_cstr));
                try c_helper.checkRocksdbErr(err_cstr, @src(), last_diag);
                defer c.rocksdb_checkpoint_object_destroy(checkpoint_object);
                c.rocksdb_checkpoint_create(checkpoint_object, path, 0, @ptrCast(&err_cstr));
                try c_helper.checkRocksdbErr(err_cstr, @src(), last_diag);
            },
        }
    }
    pub fn deinit(self: *State) void {
        switch (self.*) {
            .valid => |*handles| {
                handles.deinit();
                // recovery的移除可能报错，因此会在控制流末尾手动进行，而不会在deinit中完成。
            },
            .invalid => {},
        }
    }
    // 假定`self`是`valid`的情境下允许调用。仅用于全量写入后的延迟全量compaction。
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
        for (std.enums.values(vcaligner.rocksdb_custom.CollumFamily.cumulative_keys)) |cf_key| {
            c.rocksdb_compact_range_cf_opt(
                self.valid.db,
                self.valid.cfs.get(cf_key),
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
        self.valid.deinit();
        errdefer self.* = .invalid;
        try self.valid.initForManualCompaction(n_rocksdbjobs, compression, rocksdb_path, last_diag);
    }
    // 对于增量模式，需要在写入PrCb2Pi前清空其状态，此处使用drop以后重新创建。
    pub fn resetPrCb2Pi(
        self: *State,
        compression: bool,
        last_diag: *vcaligner.diag.Diagnostic,
    ) !void {
        var err_cstr: ?[*:0]u8 = null;
        c.rocksdb_drop_column_family(self.valid.db, self.valid.cfs.get(.pr_bc2pi), @ptrCast(&err_cstr));
        try c_helper.checkRocksdbErr(err_cstr, @src(), last_diag);
        const cf_options = blk: {
            const cf_options = c.rocksdb_options_create().?;
            applyPrBc2PiCfOptions(cf_options, compression);
            break :blk cf_options;
        };
        defer c.rocksdb_options_destroy(cf_options);
        const new_cf_handle = c.rocksdb_create_column_family(
            self.valid.db,
            cf_options,
            vcaligner.rocksdb_custom.CollumFamily.names.get(.pr_bc2pi),
            @ptrCast(&err_cstr),
        );
        try c_helper.checkRocksdbErr(err_cstr, @src(), last_diag);
        errdefer comptime unreachable;
        c.rocksdb_column_family_handle_destroy(self.valid.cfs.get(.pr_bc2pi));
        self.valid.cfs.set(.pr_bc2pi, new_cf_handle);
    }
};

pub const Handles = struct {
    db: *c.rocksdb_t,
    cfs: vcaligner.rocksdb_custom.CollumFamily.Handles,
    fn initForWrite(
        self: *Handles,
        mode: @import("PrepRunner.zig").Mode,
        n_rocksdbjobs: c_int,
        compaction_strategy: CompactionStrategy,
        compression: bool,
        cf_max_write_buffer_number: c_int,
        rocksdb_path: [:0]const u8,
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
            applyHeavyWriteOptimizationsToCfOptions(cf_options, compression, compaction_strategy, cf_max_write_buffer_number);
            break :blk cf_options;
        };
        defer c.rocksdb_options_destroy(normal_cf_options);
        var all_cf_options: std.enums.EnumArray(vcaligner.rocksdb_custom.CollumFamily, ?*c.rocksdb_options_t) = .init(.{
            .bpi2ci = undefined,
            .pi2p = normal_cf_options,
            .b_pi2bpi = undefined,
            .ci2c = normal_cf_options,
            .pr_bc2pi = undefined,
        });
        all_cf_options.set(.bpi2ci, blk: {
            const cf_options = c.rocksdb_options_create().?;
            applyHeavyWriteOptimizationsToCfOptions(cf_options, compression, compaction_strategy, cf_max_write_buffer_number);
            // 一定要小心，此处神坑！slicetransform和mergeoperator进入options时都会变成shared ptr并且移交所有权！
            // 千万不要调用C API提供的`rocksdb_slicetransform_destroy`和`rocksdb_mergeoperator_destroy`！
            // 默认列族以blob-path-id为前缀。不使用布隆过滤器，因为后续使用数据库的时候基本没有需要检查无效的key的情况。
            c.rocksdb_options_set_prefix_extractor(cf_options, c.rocksdb_slicetransform_create_fixed_prefix(@sizeOf(vcaligner.rocksdb_custom.BlobPathSeq)));
            break :blk cf_options;
        });
        defer c.rocksdb_options_destroy(all_cf_options.get(.bpi2ci));
        all_cf_options.set(.b_pi2bpi, blk: {
            const cf_options = c.rocksdb_options_create().?;
            applyHeavyWriteOptimizationsToCfOptions(cf_options, compression, compaction_strategy, cf_max_write_buffer_number);
            c.rocksdb_options_set_prefix_extractor(cf_options, c.rocksdb_slicetransform_create_fixed_prefix(@sizeOf(c.git_oid)));
            break :blk cf_options;
        });
        defer c.rocksdb_options_destroy(all_cf_options.get(.b_pi2bpi));
        all_cf_options.set(.pr_bc2pi, blk: {
            const cf_options = c.rocksdb_options_create().?;
            applyPrBc2PiCfOptions(cf_options, compression);
            break :blk cf_options;
        });
        defer c.rocksdb_options_destroy(all_cf_options.get(.pr_bc2pi));
        self.db = blk: {
            var err_cstr: ?[*:0]u8 = null;
            const db = c.rocksdb_open_column_families(
                db_options,
                rocksdb_path,
                vcaligner.rocksdb_custom.CollumFamily.names.values.len,
                @ptrCast(&vcaligner.rocksdb_custom.CollumFamily.names.values),
                &all_cf_options.values,
                &self.cfs.values,
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
        // 非默认列族（除b_pi2bpi外）的选项
        const normal_cf_options = blk: {
            const cf_options = c.rocksdb_options_create().?;
            applyFullCompactionOptimizationsToCfOptions(cf_options, compression);
            break :blk cf_options;
        };
        defer c.rocksdb_options_destroy(normal_cf_options);
        var all_cf_options: std.enums.EnumArray(vcaligner.rocksdb_custom.CollumFamily, ?*const c.rocksdb_options_t) = .init(.{
            .bpi2ci = undefined,
            .pi2p = normal_cf_options,
            .b_pi2bpi = undefined,
            .ci2c = normal_cf_options,
            .pr_bc2pi = undefined,
        });
        all_cf_options.set(.bpi2ci, blk: {
            const cf_options = c.rocksdb_options_create().?;
            applyFullCompactionOptimizationsToCfOptions(cf_options, compression);
            c.rocksdb_options_set_prefix_extractor(cf_options, c.rocksdb_slicetransform_create_fixed_prefix(@sizeOf(vcaligner.rocksdb_custom.BlobPathSeq)));
            break :blk cf_options;
        });
        defer c.rocksdb_options_destroy(all_cf_options.get(.bpi2ci));
        all_cf_options.set(.b_pi2bpi, blk: {
            const cf_options = c.rocksdb_options_create().?;
            applyFullCompactionOptimizationsToCfOptions(cf_options, compression);
            c.rocksdb_options_set_prefix_extractor(cf_options, c.rocksdb_slicetransform_create_fixed_prefix(@sizeOf(c.git_oid)));
            break :blk cf_options;
        });
        defer c.rocksdb_options_destroy(all_cf_options.get(.b_pi2bpi));
        all_cf_options.set(.pr_bc2pi, blk: {
            const cf_options = c.rocksdb_options_create().?;
            applyPrBc2PiCfOptions(cf_options, compression);
            break :blk cf_options;
        });
        defer c.rocksdb_options_destroy(all_cf_options.get(.pr_bc2pi));
        self.db = blk: {
            var err_cstr: ?[*:0]u8 = null;
            const new_db = c.rocksdb_open_column_families(
                db_options,
                rocksdb_path,
                vcaligner.rocksdb_custom.CollumFamily.names.values.len,
                @ptrCast(vcaligner.rocksdb_custom.CollumFamily.names.values),
                &all_cf_options.values,
                &self.cfs,
                @ptrCast(&err_cstr),
            );
            try c_helper.checkRocksdbErr(err_cstr, @src(), last_diag);
            break :blk new_db.?;
        };
    }
    fn deinit(self: *Handles) void {
        var iter = std.mem.reverseIterator((&self.cfs.values)[0..]);
        while (iter.next()) |cf_handle| {
            c.rocksdb_column_family_handle_destroy(cf_handle);
        }
        c.rocksdb_close(self.db);
        self.* = undefined;
    }

    // 在`writeCumulative`中被使用的Cumulative没法复用自制的EnumArray的sub view抽象。
    // 主要是因为`rocksdb_flush_cfs`中对于绝对稠密的数组的需求，因而此处必须是重新构造的数组，而不能是完整array的视图。
    pub const Cumulative = struct {
        db: *c.rocksdb_t,
        cfs: std.enums.EnumArray(vcaligner.sub_enum.SubEnum(
            vcaligner.rocksdb_custom.CollumFamily,
            vcaligner.rocksdb_custom.CollumFamily.cumulative_keys,
        ), ?*c.rocksdb_column_family_handle_t),
        pub fn fromFullStorage(noalias storage: *const Handles) Cumulative {
            return .{ .db = storage.db, .cfs = .init(.{
                .bpi2ci = storage.cfs.get(.bpi2ci),
                .pi2p = storage.cfs.get(.pi2p),
                .b_pi2bpi = storage.cfs.get(.b_pi2bpi),
                .ci2c = storage.cfs.get(.ci2c),
            }) };
        }
    };
};

fn applyHeavyWriteOptimizationsToCfOptions(
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

fn applyFullCompactionOptimizationsToCfOptions(
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

pub fn applyPrBc2PiCfOptions(
    options: *c.rocksdb_options_t,
    compression: bool,
) void {
    // pr_bc2pi列族有以下特征：
    // 它永远只需要sstFileWriter写入和读取。
    // 它的读取永远都是全量扫描。
    // 因此，单个巨大的sst文件是最优的。我们不需要compaction，既不需要自动，也不需要手动，只需要一个巨大的sst文件。
    // `target_file_size_base`对于sstFileWriter写入的sst文件大小没有影响。
    // 而只要不进行写入，也不会触发compaction，因此不需要禁用自动compaction。
    if (compression) {
        c.rocksdb_options_set_compression(options, c.rocksdb_lz4_compression);
    }
}
