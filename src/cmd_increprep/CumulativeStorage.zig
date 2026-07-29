/// 包括可以一边解析一边写入的列族句柄的数据库对象。不包括Full-Rebuild的pr2pi列族。
const std = @import("std");
const vcaligner = @import("vcaligner");
const c_helper = vcaligner.c_helper;
const c = c_helper.c;
const CompactionStrategy = @import("PrepRunner.zig").CompactionStrategy;

const CumulativeStorage = @This();

db: *c.rocksdb_t,
cf_handles: std.enums.EnumArray(CollumFamily, *c.rocksdb_column_family_handle_t),

pub const CollumFamily = enum(std.meta.Tag(vcaligner.rocksdb_custom.CollumFamily)) {
    bpi_ci = @intFromEnum(vcaligner.rocksdb_custom.CollumFamily.b_pi_bpi),
    pi_p = @intFromEnum(vcaligner.rocksdb_custom.CollumFamily.pi_p),
    b_pi_bpi = @intFromEnum(vcaligner.rocksdb_custom.CollumFamily.b_pi_bpi),
    ci_c = @intFromEnum(vcaligner.rocksdb_custom.CollumFamily.ci_c),
};

// 打开数据库及各列族，覆盖 1.增量模式下的读取现有列族阶段；2.写入阶段
// 如果写入阶段有自动compaction，此配置将覆盖pr2pi列族的写入。否则，此配置将在全量compaction中被重置。
pub fn init(
    mode: @import("PrepRunner.zig").Mode,
    n_rocksdbjobs: c_int,
    compression: bool,
    compaction_strategy: CompactionStrategy,
    cf_max_write_buffer_number: c_int,
    rocksdb_path: @import("preprocess.zig").RocksdbPath,
    last_diag: *vcaligner.diag.Diagnostic,
) !CumulativeStorage {
    const db = db: {
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

            // 从此开始为默认列族配置而非数据库整体配置。
            applyHeavyWriteOptimizations(db_options, n_rocksdbjobs, compression, compaction_strategy, cf_max_write_buffer_number);
            // 一定要小心，此处神坑！slicetransform和mergeoperator进入options时都会变成shared ptr并且移交所有权！
            // 千万不要调用C API提供的`rocksdb_slicetransform_destroy`和`rocksdb_mergeoperator_destroy`！
            // 默认列族以blob-path-id为前缀。不使用布隆过滤器，因为后续使用数据库的时候基本没有需要检查无效的key的情况。
            c.rocksdb_options_set_prefix_extractor(db_options, c.rocksdb_slicetransform_create_fixed_prefix(@sizeOf(vcaligner.rocksdb_custom.BlobPathSeq)));
            // NOTE：当options已经被用于打开rocksdb以后，rocksdb内部有此配置的拷贝，对options的直接修改不会影响rocksdb。
            // 虽然后续可以用`rocksdb_set_options`和`rocksdb_set_options_cf`中途修改各默认列族的行为。
            // 但是，C API不支持`SetDBOptions`，也就是修改数据库本体的操作。后续必须关闭数据库再重新打开。
            break :blk db_options;
        };
        defer c.rocksdb_options_destroy(db_options);
        var err_cstr: ?[*:0]u8 = null;
        const db = c.rocksdb_open(db_options, rocksdb_path.get(), @ptrCast(&err_cstr));
        try c_helper.checkRocksdbErr(err_cstr, @src(), last_diag);
        break :db db.?;
    };
    errdefer c.rocksdb_close(db);
    var cf_handles: std.enums.EnumArray(CollumFamily, *c.rocksdb_column_family_handle_t) = .initUndefined();
    // 默认列族
    cf_handles.set(.bpi_ci, c.rocksdb_get_default_column_family_handle(db).?);
    errdefer c.rocksdb_column_family_handle_destroy(cf_handles.get(.bpi_ci));
    create_ci2c_and_pi2p: {
        // 为其它列族设置单独的默认配置(除了b_pi_bpi以外）（它们不需要前缀提取器）
        // 尽管可能的写入方式仍然存在一些区别，简单考虑依旧使用相同的配置。
        const cf_options = blk: {
            const cf_options = c.rocksdb_options_create();
            applyHeavyWriteOptimizations(cf_options, n_rocksdbjobs, compression, compaction_strategy, cf_max_write_buffer_number);
            break :blk cf_options.?;
        };
        defer c.rocksdb_options_destroy(cf_options);
        cf_handles.set(.ci_c, blk: {
            var err_cstr: ?[*:0]u8 = null;
            const cf_ci_c = c.rocksdb_create_column_family(db, cf_options, vcaligner.rocksdb_custom.cf_names.get(.ci_c), @ptrCast(&err_cstr));
            try c_helper.checkRocksdbErr(err_cstr, @src(), last_diag);
            break :blk cf_ci_c.?;
        });
        errdefer c.rocksdb_column_family_handle_destroy(cf_handles.get(.ci_c));
        cf_handles.set(.pi_p, blk: {
            var err_cstr: ?[*:0]u8 = null;
            const cf_pi_p = c.rocksdb_create_column_family(db, cf_options, vcaligner.rocksdb_custom.cf_names.get(.pi_p), @ptrCast(&err_cstr));
            try c_helper.checkRocksdbErr(err_cstr, @src(), last_diag);
            break :blk cf_pi_p.?;
        });
        errdefer comptime unreachable;
        break :create_ci2c_and_pi2p;
    }
    errdefer {
        c.rocksdb_column_family_handle_destroy(cf_handles.get(.pi_p));
        c.rocksdb_column_family_handle_destroy(cf_handles.get(.ci_c));
    }
    create_b_pi2bpi: {
        const cf_b_pi_bpi_options = blk: {
            const cf_b_pi_bpi_options = c.rocksdb_options_create();
            applyHeavyWriteOptimizations(cf_b_pi_bpi_options, n_rocksdbjobs, compression, compaction_strategy, cf_max_write_buffer_number);
            c.rocksdb_options_set_prefix_extractor(cf_b_pi_bpi_options, c.rocksdb_slicetransform_create_fixed_prefix(@sizeOf(c.git_oid)));
            break :blk cf_b_pi_bpi_options.?;
        };
        defer c.rocksdb_options_destroy(cf_b_pi_bpi_options);
        cf_handles.set(.b_pi_bpi, blk: {
            var err_cstr: ?[*:0]u8 = null;
            const cf_b_pi_bpi = c.rocksdb_create_column_family(db, cf_b_pi_bpi_options, vcaligner.rocksdb_custom.cf_names.get(.b_pi_bpi), @ptrCast(&err_cstr));
            try c_helper.checkRocksdbErr(err_cstr, @src(), last_diag);
            break :blk cf_b_pi_bpi.?;
        });
        errdefer comptime unreachable;
        break :create_b_pi2bpi;
    }
    errdefer comptime unreachable;
    return .{ .db = db, .cf_handles = cf_handles };
}
fn applyHeavyWriteOptimizations(
    db_options: *c.rocksdb_options_t,
    n_rocksdbjobs: c_int,
    compression: bool,
    compaction_strategy: CompactionStrategy,
    cf_max_write_buffer_number: c_int,
) void {
    if (compression) {
        // 关于压缩：原则上compaction阶段的压缩才影响最终大小，而写入阶段的压缩只影响中间文件大小而不影响最终大小。
        // 但是，在对postgresql的测试中，如果compaction阶段都不压缩，而只检验写入阶段的压缩，发现写入阶段压缩比不压缩反而快30秒左右（13分50秒与14分36秒的区别）
        // 这说明中间文件的大小变小实际上由于降低了I/O量，导致中间过程的压缩也反而对性能有益而非有害。
        c.rocksdb_options_set_compression(db_options, c.rocksdb_lz4_compression);
    }
    sw: switch (compaction_strategy) {
        .manual_delayed => {
            // 手动延迟全量compaction，即写入时不compaction，即采用prepare for bulk load配置。
            //此配置为关键混合配置：部分影响数据库行为，部分影响默认列族的行为。
            // FAQ说这个函数会使用vector memtable。如果是这样的话，对我这种乱序写入的场景就不适合了。
            // 但是，所幸的是，看了[源码](https://github.com/facebook/rocksdb/blob/a34683bf543cc3eb151d08eeac00791862acd4d6/options/options.cc#L478-L519)
            // 实际没有修改memtable使用类型的行为，仅仅是全部写入L0以及禁止自动压缩。这些行为都是我需要的，可以放心使用。
            // 这个行为会设置`flush`线程为4。不用担心`flush`线程数影响parser等其他线程，因为这是I/O密集线程，不怎么影响计算线程。
            c.rocksdb_options_prepare_for_bulk_load(db_options);
            c.rocksdb_options_set_max_background_flushes(db_options, n_rocksdbjobs);
        },
        .auto_with_trigger => |compaction_trigger| {
            // 自动compaction，但配置了触发器
            c.rocksdb_options_set_level0_file_num_compaction_trigger(db_options, compaction_trigger);
            c.rocksdb_options_set_level0_slowdown_writes_trigger(db_options, compaction_trigger * 2);
            c.rocksdb_options_set_level0_stop_writes_trigger(db_options, compaction_trigger * 4);
            // 其余配置和自动触发器相同。
            continue :sw .auto_default;
        },
        .auto_default => {
            // 自动compaction。下面的配置部分抄自prepare for bulk load内部实现，适用于大量数据写入。
            // 但不要像prepare for bulk load那样减少compaction层级，以及修改最大compation大小。
            // 各列族的最大write buffer number将在后文通过参数配置。
            c.rocksdb_options_set_min_write_buffer_number_to_merge(db_options, 1);
            c.rocksdb_options_set_target_file_size_base(db_options, 256 * 1024 * 1024);
            // flush和compaction的线程分配交给前面的`rocksdb_options_increase_parallelism`自动进行。
        },
    }
    // 以下为各个列族相关配置
    // 增加`write_buffer_size`。目前默认的64MB可能导致多个小sst文件，增大单个sst文件的大小，降低文件数量，以避免文件打开与关闭开销。
    c.rocksdb_options_set_write_buffer_size(db_options, 256 * 1024 * 1024);
    c.rocksdb_options_set_max_write_buffer_number(db_options, cf_max_write_buffer_number);
}

pub fn deinit(self: *CumulativeStorage) void {
    c.rocksdb_column_family_handle_destroy(self.cf_handles.get(.b_pi_bpi));
    c.rocksdb_column_family_handle_destroy(self.cf_handles.get(.pi_p));
    c.rocksdb_column_family_handle_destroy(self.cf_handles.get(.ci_c));
    c.rocksdb_column_family_handle_destroy(self.cf_handles.get(.bpi_ci));
    c.rocksdb_close(self.db);
    self.* = undefined;
}

pub fn reopenForFullCompaction(self: *CumulativeStorage) !void {
    // TODO:
    _ = self;
}
