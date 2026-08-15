const std = @import("std");
pub const c = @cImport({
    @cInclude("git2.h");
    @cInclude("rocksdb/c.h");
});
const diag = @import("diagnostics.zig");
test "libgit2 test" {
    _ = c.git_libgit2_init();
    _ = c.git_libgit2_shutdown();
}
test "rocksdb test" {
    const options = c.rocksdb_options_create();
    c.rocksdb_options_set_create_if_missing(options, 1);
    c.rocksdb_options_destroy(options);
}

pub const Libgit2Error = error{
    GIT_ERROR,
    GIT_ENOTFOUND,
    GIT_EEXISTS,
    GIT_EAMBIGUOUS,
    GIT_EBUFS,
    GIT_EUSER,
    GIT_EBAREREPO,
    GIT_EUNBORNBRANCH,
    GIT_EUNMERGED,
    GIT_ENONFASTFORWARD,
    GIT_EINVALIDSPEC,
    GIT_ECONFLICT,
    GIT_ELOCKED,
    GIT_EMODIFIED,
    GIT_EAUTH,
    GIT_ECERTIFICATE,
    GIT_EAPPLIED,
    GIT_EPEEL,
    GIT_EEOF,
    GIT_EINVALID,
    GIT_EUNCOMMITTED,
    GIT_EDIRECTORY,
    GIT_EMERGECONFLICT,
    GIT_PASSTHROUGH,
    GIT_ITEROVER,
    GIT_RETRY,
    GIT_EMISMATCH,
    GIT_EINDEXDIRTY,
    GIT_EAPPLYFAIL,
    GIT_EOWNER,
    GIT_TIMEOUT,
    GIT_EUNCHANGED,
    GIT_ENOTSUPPORTED,
    GIT_EREADONLY,
    UnknownCError,
};

// 我能想到的一种可能的处理方法是：编译时遍历`Libgit2Error`的错误名，然后用`@field`访问其声明，分别与`git_error_code`进行比较。
// 但是，即使遍历得到了匹配的错误名，但依旧没有任何办法直接得到错误。因此，目前手工制作该表是唯一解。
// TODO: 重构请求：没有必要把`Libgit2Error`设计为一个错误集，既然它们的处理方式相同，那么只需要设计为报告单个`Libgit2Error`错误即可。
// 具体的错误与分析逻辑到了diag结构里使用标签联合体分析。
pub fn gitErrorCodeToZigError(git_error_code: c_int, last_diag: *diag.Diagnostic) (Libgit2Error || error{UnableToConstructDiagnostic})!void {
    return switch (git_error_code) {
        c.GIT_OK => return,
        c.GIT_ERROR => blk: {
            last_diag.* = .{ .GIT_ERROR = DiagnosticGIT_ERROR.init(last_diag.getAllocator()) catch |e| {
                return last_diag.unableToConstructDiagnostic(e);
            } };
            break :blk Libgit2Error.GIT_ERROR;
        },
        c.GIT_ENOTFOUND => Libgit2Error.GIT_ENOTFOUND,
        c.GIT_EEXISTS => Libgit2Error.GIT_EEXISTS,
        c.GIT_EAMBIGUOUS => Libgit2Error.GIT_EAMBIGUOUS,
        c.GIT_EBUFS => Libgit2Error.GIT_EBUFS,
        c.GIT_EUSER => Libgit2Error.GIT_EUSER,
        c.GIT_EBAREREPO => Libgit2Error.GIT_EBAREREPO,
        c.GIT_EUNBORNBRANCH => Libgit2Error.GIT_EUNBORNBRANCH,
        c.GIT_EUNMERGED => Libgit2Error.GIT_EUNMERGED,
        c.GIT_ENONFASTFORWARD => Libgit2Error.GIT_ENONFASTFORWARD,
        c.GIT_EINVALIDSPEC => Libgit2Error.GIT_EINVALIDSPEC,
        c.GIT_ECONFLICT => Libgit2Error.GIT_ECONFLICT,
        c.GIT_ELOCKED => Libgit2Error.GIT_ELOCKED,
        c.GIT_EMODIFIED => Libgit2Error.GIT_EMODIFIED,
        c.GIT_EAUTH => Libgit2Error.GIT_EAUTH,
        c.GIT_ECERTIFICATE => Libgit2Error.GIT_ECERTIFICATE,
        c.GIT_EAPPLIED => Libgit2Error.GIT_EAPPLIED,
        c.GIT_EPEEL => Libgit2Error.GIT_EPEEL,
        c.GIT_EEOF => Libgit2Error.GIT_EEOF,
        c.GIT_EINVALID => Libgit2Error.GIT_EINVALID,
        c.GIT_EUNCOMMITTED => Libgit2Error.GIT_EUNCOMMITTED,
        c.GIT_EDIRECTORY => Libgit2Error.GIT_EDIRECTORY,
        c.GIT_EMERGECONFLICT => Libgit2Error.GIT_EMERGECONFLICT,
        c.GIT_PASSTHROUGH => Libgit2Error.GIT_PASSTHROUGH,
        c.GIT_ITEROVER => Libgit2Error.GIT_ITEROVER,
        c.GIT_RETRY => Libgit2Error.GIT_RETRY,
        c.GIT_EMISMATCH => Libgit2Error.GIT_EMISMATCH,
        c.GIT_EINDEXDIRTY => Libgit2Error.GIT_EINDEXDIRTY,
        c.GIT_EAPPLYFAIL => Libgit2Error.GIT_EAPPLYFAIL,
        c.GIT_EOWNER => Libgit2Error.GIT_EOWNER,
        c.GIT_TIMEOUT => Libgit2Error.GIT_TIMEOUT,
        c.GIT_EUNCHANGED => Libgit2Error.GIT_EUNCHANGED,
        c.GIT_ENOTSUPPORTED => Libgit2Error.GIT_ENOTSUPPORTED,
        c.GIT_EREADONLY => Libgit2Error.GIT_EREADONLY,
        else => blk: {
            last_diag.* = .{ .UnknownCError = .{ .code = git_error_code } };
            break :blk Libgit2Error.UnknownCError;
        },
    };
}

pub const DiagnosticGIT_ERROR = struct {
    message: [:0]u8,
    klass: c_int,
    pub fn init(allocator: std.mem.Allocator) !DiagnosticGIT_ERROR {
        // TODO: last_error理应是线程安全的，但是可能需要增加一个检测libgit2特性确定其是否支持线程安全的断言。
        const last_error: *const c.git_error = c.git_error_last();
        const message: [:0]u8 = try std.fmt.allocPrintSentinel(allocator, "{s}", .{last_error.message}, 0);
        errdefer comptime unreachable;
        return .{
            .klass = last_error.klass,
            .message = message,
        };
    }
    pub fn log(self: DiagnosticGIT_ERROR) void {
        std.log.err("libgit2: {s}\n", .{self.message});
    }
};

pub const DiagnosticUnknownCError = struct {
    code: c_int,
    pub fn log(self: DiagnosticUnknownCError) void {
        std.log.err("unknown c: {d}\n", .{self.code});
    }
};

pub const DiagnosticRocksdbError = struct {
    message: [:0]u8,
    src: std.builtin.SourceLocation,
    pub fn init(ecstr: [*:0]u8, src: std.builtin.SourceLocation, allocator: std.mem.Allocator) !DiagnosticRocksdbError {
        const message: [:0]u8 = try std.fmt.allocPrintSentinel(allocator, "{s}", .{ecstr}, 0);
        errdefer comptime unreachable;
        return .{ .message = message, .src = src };
    }
    pub fn log(self: DiagnosticRocksdbError) void {
        std.log.err("rocksdb: {s}\n{s}:{s}:{s}:{d}:{d}", .{
            self.message,
            self.src.module,
            self.src.file,
            self.src.fn_name,
            self.src.line,
            self.src.column,
        });
    }
};

pub fn checkRocksdbErr(err_cstr: ?[*:0]u8, src: std.builtin.SourceLocation, last_diag: *diag.Diagnostic) error{ RocksdbError, UnableToConstructDiagnostic }!void {
    if (err_cstr) |ecstr| {
        defer c.rocksdb_free(ecstr);
        last_diag.* = .{ .RocksdbError = DiagnosticRocksdbError.init(ecstr, src, last_diag.getAllocator()) catch |e| {
            return last_diag.unableToConstructDiagnostic(e);
        } };
        return error.RocksdbError;
    }
    return;
}
