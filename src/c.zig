const std = @import("std");
pub const c = @cImport({
    @cInclude("git2.h");
    @cInclude("rocksdb/c.h");
});
const LastError = @import("error.zig").LastError;
test "libgit2 test" {
    _ = c.git_libgit2_init();
    _ = c.git_libgit2_shutdown();
}
test "rocksdb test" {
    const options = c.rocksdb_options_create();
    c.rocksdb_options_set_create_if_missing(options, 1);
    c.rocksdb_options_destroy(options);
}

pub const Libgit2Error = error{ GIT_ERROR, GIT_ENOTFOUND, GIT_EEXISTS, GIT_EAMBIGUOUS, GIT_EBUFS, GIT_EUSER, GIT_EBAREREPO, GIT_EUNBORNBRANCH, GIT_EUNMERGED, GIT_ENONFASTFORWARD, GIT_EINVALIDSPEC, GIT_ECONFLICT, GIT_ELOCKED, GIT_EMODIFIED, GIT_EAUTH, GIT_ECERTIFICATE, GIT_EAPPLIED, GIT_EPEEL, GIT_EEOF, GIT_EINVALID, GIT_EUNCOMMITTED, GIT_EDIRECTORY, GIT_EMERGECONFLICT, GIT_PASSTHROUGH, GIT_ITEROVER, GIT_RETRY, GIT_EMISMATCH, GIT_EINDEXDIRTY, GIT_EAPPLYFAIL, GIT_EOWNER, GIT_TIMEOUT, GIT_EUNCHANGED, GIT_ENOTSUPPORTED, GIT_EREADONLY, UnknownCError };

// 我能想到的一种可能的处理方法是：编译时遍历`Libgit2Error`的错误名，然后用`@field`访问其声明，分别与`git_error_code`进行比较。
pub fn gitErrorCodeToZigError(git_error_code: c_int, last_error_out: *LastError) Libgit2Error!void {
    return switch (git_error_code) {
        c.GIT_OK => return,
        c.GIT_ERROR => git_error_blk: {
            last_error_out.* = .{ .libgit2 = c.git_error_last() };
            break :git_error_blk Libgit2Error.GIT_ERROR;
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
        else => unknown_error_blk: {
            last_error_out.* = .{ .unknown_c_error = git_error_code };
            break :unknown_error_blk Libgit2Error.UnknownCError;
        },
    };
}

pub fn logLibgit2Error(err: Libgit2Error, last_error: LastError) void {
    switch (err) {
        Libgit2Error.GIT_ERROR => {
            std.log.err("libgit2: {s}\n", .{(last_error.libgit2 orelse c.git_error_last()).*.message});
        },
        error.UnknownCError => {
            std.log.err("unknown c: {d}\n", .{last_error.unknown_c_error});
        },
        else => {
            std.log.err("libgit2: {s}\n", .{@errorName(err)});
        },
    }
}
