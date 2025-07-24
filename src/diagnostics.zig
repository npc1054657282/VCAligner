const std = @import("std");
const c = @import("c.zig").c;

pub const Diagnostics = struct {
    arena: std.heap.ArenaAllocator,
    error_stack: std.ArrayListUnmanaged(Error) = .empty,
    last_diagnostic: Diagnostic = undefined,
    double_error: ?anyerror = null,
    pub const Error = struct {
        code: anyerror,
        diagnostic: Diagnostic,
    };
    pub fn clear(self: *Diagnostics) void {
        _ = self.arena.reset(.free_all);
        self.error_stack = .empty;
        self.last_diagnostic = undefined;
        self.double_error = null;
    }
    pub fn log_all(self: *Diagnostics, last_error: ?anyerror) void {
        if (last_error) |err| {
            if (self.double_error) |double_error| {
                std.log.err("double error!{s}", .{@errorName(double_error)});
            }
            self.last_diagnostic.log(err);
            var it = std.mem.reverseIterator(self.error_stack.items);
            while (it.nextPtr()) |item| {
                item.diagnostic.log(item.code);
            }
        } else return;
    }
};

pub const Diagnostic = union {
    DiagnosticGIT_ERROR: @import("c.zig").DiagnosticGIT_ERROR,
    DiagnosticUnknownCError: @import("c.zig").DiagnosticUnknownCError,
    pub fn enterStack(last_diagnostic: *@This(), last_error: anyerror) !void {
        var diagnostics: *Diagnostics = @fieldParentPtr("last_diagnostic", last_diagnostic);
        if (diagnostics.double_error != null) {
            return last_error;
        }
        diagnostics.error_stack.append(diagnostics.arena.allocator(), .{ .code = last_error, .diagnostic = last_diagnostic.* }) catch |double_error| {
            diagnostics.double_error = double_error;
            return last_error;
        };
        last_diagnostic.* = undefined;
    }
    pub fn getAllocator(last_diagnostic: *@This()) std.mem.Allocator {
        const diagnostics: *Diagnostics = @fieldParentPtr("last_diagnostic", last_diagnostic);
        return diagnostics.arena.allocator();
    }
    pub fn unableToConstructDiagnostic(last_diagnostic: *@This(), err: anyerror) !void {
        const diagnostics: *Diagnostics = @fieldParentPtr("last_diagnostic", last_diagnostic);
        diagnostics.double_error = err;
        return error.UnableToConstructDiagnostic;
    }

    pub fn log(self: *Diagnostic, err: anyerror) void {
        inline for (@typeInfo(Diagnostic).@"union".fields) |field| {
            if (std.mem.eql(u8, @errorName(err), field.name)) {
                if (@hasDecl(@FieldType(Diagnostic, field.name), "log")) {
                    @field(self, field.name).log();
                } else {
                    std.log.err("{s}:{}\n", .{ field.name, @field(self, field.name) });
                }
                return;
            }
        }
        std.log.err("{s}\n", .{@errorName(err)});
    }
};

pub fn inErrorSet(comptime err: anyerror, comptime Err: type) bool {
    if (@typeInfo(Err).error_set) |error_set| inline for (error_set) |err_info| {
        if (std.mem.eql(u8, @errorName(err), err_info.name)) {
            return true;
        }
    };
    return false;
}
