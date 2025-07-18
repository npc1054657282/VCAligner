const std = @import("std");

pub const Logger = struct {
    v_log: *const fn (*Logger, []const u8) void,
    v_setLevel: *const fn (*Logger, usize) void,
    pub fn log(self: *Logger, msg: []const u8) void {
        self.v_log(self, msg);
    }
    pub fn setLevel(self: *Logger, level: usize) void {
        self.v_setLevel(self, level);
    }
    pub fn implBy(comptime T: type) Logger {
        const impl = struct {
            pub fn log(ptr: *Logger, msg: []const u8) void {
                var self: *T = @fieldParentPtr("logger", ptr);
                self.log(msg);
            }
            pub fn setLevel(ptr: *Logger, level: usize) void {
                var self: *T = @fieldParentPtr("logger", ptr);
                self.setLevel(level);
            }
        };
        return .{
            .v_log = impl.log,
            .v_setLevel = impl.setLevel,
        };
    }
};

pub const DbgLogger = struct {
    logger: Logger = Logger.implBy(DbgLogger),
    level: usize = 0,
    count: usize = 0,

    pub fn log(self: *DbgLogger, msg: []const u8) void {
        self.count += 1;
        std.debug.print("{d}: [level {d}] {s}\n", .{ self.count, self.level, msg });
    }

    pub fn setLevel(self: *DbgLogger, level: usize) void {
        self.level = level;
    }
};

pub const FileLogger = struct {
    logger: Logger,
    file: std.fs.File,

    pub fn init(path: []const u8) !FileLogger {
        return .{
            .file = try std.fs.cwd().createFile(path, .{ .read = false }),
            .logger = Logger.implBy(FileLogger),
        };
    }

    pub fn deinit(self: *FileLogger) void {
        self.file.close();
    }

    pub fn log(self: *FileLogger, msg: []const u8) void {
        self.file.writer().print("{s}\n", .{msg}) catch |err| std.debug.print("Err: {any}\n", .{err});
    }

    pub fn setLevel(self: *FileLogger, level: usize) void {
        self.file.writer().print("== New Level {d} ==\n", .{level}) catch |err| std.debug.print("Err: {any}\n", .{err});
    }
};

test "embedded vtab example" {
    var dbg_logger = DbgLogger{};
    var logger1 = &dbg_logger.logger;
    logger1.log("Hello1");
    logger1.log("Hello2");
    logger1.setLevel(2);
    logger1.log("Hello3");

    var file_logger = try FileLogger.init("log.txt");
    defer file_logger.deinit();
    var logger2 = &file_logger.logger;
    logger2.log("Hello1");
    logger2.setLevel(3);
    logger2.log("Hello2");
    logger2.log("Hello3");

    const loggers = [_]*Logger{ logger1, logger2 };
    for (loggers) |l|
        l.log("Hello to all loggers");
}

test "type field struct" {
    const Policy = struct {
        fn run() void {
            std.debug.print("do something\n", .{});
        }
    };
    const TypeA = struct {
        T: type,
    };
    const a: TypeA = .{ .T = Policy };
    a.T.run();
}
