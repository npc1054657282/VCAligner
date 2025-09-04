const std = @import("std");

pub const Diagnostics = struct {
    allocator: std.mem.Allocator,
    error_stack: std.ArrayList(Error) = .empty,
    last_diagnostic: Diagnostic = .{ .empty = {} },
    double_error: ?anyerror = null,
    pub const Error = struct {
        code: anyerror,
        diagnostic: Diagnostic,
    };
    pub fn clear(self: *Diagnostics, last_error: ?anyerror) void {
        if (last_error) |err| {
            (&self.last_diagnostic).deinit(err, self.allocator);
        }
        for (self.error_stack.items) |*item| {
            (&item.diagnostic).deinit(item.code, self.allocator);
        }
        self.error_stack.deinit(self.allocator);
        self.error_stack = .empty;
    }
    pub fn print_all(self: *Diagnostics, last_error: ?anyerror) void {
        if (last_error) |err| {
            if (self.double_error) |double_error| {
                std.debug.print("double error!{s}", .{@errorName(double_error)});
            }
            (&self.last_diagnostic).print(err);
            var it = std.mem.reverseIterator(self.error_stack.items);
            while (it.nextPtr()) |item| {
                (&item.diagnostic).print(item.code);
            }
        } else return;
    }
};

pub const Diagnostic = union {
    empty: void,
    TarUnableToCreateSymLink: struct {
        file_name: []const u8,
        link_name: []const u8,
        fn print(self: @This()) void {
            std.debug.print("file_name: {s} link_name: {s}\n", .{ self.file_name, self.link_name });
        }
        fn deinit(self: @This(), allocator: std.mem.Allocator) void {
            allocator.free(self.file_name);
            allocator.free(self.link_name);
        }
    },
    TarComponentsOutsideStrippedPrefix: struct {
        file_name: []const u8,
        fn print(self: @This()) void {
            std.debug.print("file_name: {s}\n", .{self.file_name});
        }
        fn deinit(self: @This(), allocator: std.mem.Allocator) void {
            allocator.free(self.file_name);
        }
    },
    pub fn enterStack(last_diagnostic: *@This(), last_error: anyerror) !void {
        var diagnostics: *Diagnostics = @fieldParentPtr("last_diagnostic", last_diagnostic);
        if (diagnostics.double_error != null) {
            return last_error;
        }
        diagnostics.error_stack.append(diagnostics.allocator, .{ .code = last_error, .diagnostic = last_diagnostic.* }) catch |double_error| {
            diagnostics.double_error = double_error;
            return last_error;
        };
        last_diagnostic.* = undefined;
    }
    pub fn getAllocator(last_diagnostic: *@This()) std.mem.Allocator {
        const diagnostics: *Diagnostics = @fieldParentPtr("last_diagnostic", last_diagnostic);
        return diagnostics.allocator;
    }
    pub fn unableToConstructDiagnostic(last_diagnostic: *@This(), err: anyerror) !void {
        const diagnostics: *Diagnostics = @fieldParentPtr("last_diagnostic", last_diagnostic);
        diagnostics.double_error = err;
        return error.UnableToConstructDiagnostic;
    }

    pub fn print(self: *Diagnostic, err: anyerror) void {
        inline for (@typeInfo(Diagnostic).@"union".fields) |field| {
            if (comptime std.mem.eql(u8, field.name, "empty")) continue;
            if (std.mem.eql(u8, @errorName(err), field.name)) {
                if (@hasDecl(@FieldType(Diagnostic, field.name), "print")) {
                    @field(self, field.name).print();
                } else {
                    std.debug.print("{s}:{}\n", .{ field.name, @field(self, field.name) });
                }
                return;
            }
        }
        std.debug.print("{s}\n", .{@errorName(err)});
    }
    pub fn deinit(self: *Diagnostic, err: anyerror, allocator: std.mem.Allocator) void {
        inline for (@typeInfo(Diagnostic).@"union".fields) |field| {
            if (comptime std.mem.eql(u8, field.name, "empty")) continue;
            if (std.mem.eql(u8, @errorName(err), field.name)) {
                if (@hasDecl(@FieldType(Diagnostic, field.name), "deinit")) {
                    @field(self, field.name).deinit(allocator);
                }
                return;
            }
        }
    }
};

// Creates a symbolic link at path `file_name` which points to `link_name`.
fn createDirAndSymlink(dir: std.fs.Dir, link_name: []const u8, file_name: []const u8) !void {
    dir.symLink(link_name, file_name, .{}) catch |err| {
        if (err == error.FileNotFound) {
            if (std.fs.path.dirname(file_name)) |dir_name| {
                try dir.makePath(dir_name);
                return try dir.symLink(link_name, file_name, .{});
            }
        }
        return err;
    };
}

test "create dir and symlink" {
    var root = std.testing.tmpDir(.{});
    defer root.cleanup();

    createDirAndSymlink(root.dir, "a/b/c/file2", "symlink1") catch |err| {
        // On Windows when developer mode is not enabled
        if (err == error.AccessDenied) return error.SkipZigTest;
        return err;
    };
    try createDirAndSymlink(root.dir, "../../../file1", "d/e/f/symlink2");

    // Danglink symlnik, file created later
    try createDirAndSymlink(root.dir, "../../../g/h/i/file4", "j/k/l/symlink3");
}

fn stripComponents(path: []const u8, count: u32) []const u8 {
    var i: usize = 0;
    var c = count;
    while (c > 0) : (c -= 1) {
        if (std.mem.indexOfScalarPos(u8, path, i, '/')) |pos| {
            i = pos + 1;
        } else {
            i = path.len;
            break;
        }
    }
    return path[i..];
}

fn foo(last_diagnostic: *Diagnostic) !void {
    const path_names = [_][]const u8{ "hello", "world" };
    for (path_names) |path_name| {
        const file_name = stripComponents(path_name, 1);
        if (file_name.len == 0) {
            last_diagnostic.* = .{ .TarComponentsOutsideStrippedPrefix = .{
                .file_name = last_diagnostic.getAllocator().dupe(u8, file_name) catch |err| {
                    return last_diagnostic.unableToConstructDiagnostic(err);
                },
            } };
            return error.TarComponentsOutsideStrippedPrefix;
        }
        var root = std.testing.tmpDir(.{});
        defer root.cleanup();
        const link_name = "link";
        createDirAndSymlink(root.dir, link_name, file_name) catch |err| {
            try last_diagnostic.enterStack(err);
            last_diagnostic.* = .{ .TarUnableToCreateSymLink = .{
                .file_name = last_diagnostic.getAllocator().dupe(u8, file_name) catch |e| {
                    return last_diagnostic.unableToConstructDiagnostic(e);
                },
                .link_name = last_diagnostic.getAllocator().dupe(u8, link_name) catch |e| {
                    return last_diagnostic.unableToConstructDiagnostic(e);
                },
            } };
            return error.TarUnableToCreateSymLink;
        };
    }
}

fn bar(last_diagnostic: *Diagnostic) !void {
    const path_names = [_][]const u8{ "hello/world", "world/hello" };
    for (path_names) |path_name| {
        const file_name = stripComponents(path_name, 1);
        if (file_name.len == 0) {
            last_diagnostic.* = .{ .TarComponentsOutsideStrippedPrefix = .{
                .file_name = last_diagnostic.getAllocator().dupe(u8, file_name) catch |err| {
                    return last_diagnostic.unableToConstructDiagnostic(err);
                },
            } };
            return error.TarComponentsOutsideStrippedPrefix;
        }
        var root = std.testing.tmpDir(.{});
        defer root.cleanup();
        const link_name = "link";
        createDirAndSymlink(root.dir, link_name, file_name) catch |err| {
            try last_diagnostic.enterStack(err);
            last_diagnostic.* = .{ .TarUnableToCreateSymLink = .{
                .file_name = last_diagnostic.getAllocator().dupe(u8, file_name) catch |e| {
                    return last_diagnostic.unableToConstructDiagnostic(e);
                },
                .link_name = last_diagnostic.getAllocator().dupe(u8, link_name) catch |e| {
                    return last_diagnostic.unableToConstructDiagnostic(e);
                },
            } };
            return error.TarUnableToCreateSymLink;
        };
    }
}

test "new diagnostics" {
    const root_allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(root_allocator);
    defer arena.deinit();
    var diagnostics: Diagnostics = .{ .allocator = arena.allocator() };
    foo(&diagnostics.last_diagnostic) catch |err| {
        (&diagnostics).print_all(err);
        (&diagnostics).clear(err);
    };
    bar(&diagnostics.last_diagnostic) catch |err| {
        (&diagnostics).print_all(err);
        (&diagnostics).clear(err);
    };
}
