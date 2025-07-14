const std = @import("std");
const BuildConfig = struct { add_include_paths: [][]const u8, add_library_paths: [][]const u8, link_system_librarys: [][]const u8 };

fn readBuildConfig(allocator: std.mem.Allocator) !BuildConfig {
    const raw_build_config = @embedFile("build_config.json");
    const parsed = try std.json.parseFromSlice(
        BuildConfig,
        allocator,
        raw_build_config,
        .{},
    );
    return parsed.value;
}

pub fn build(b: *std.Build) void {
    const build_config = readBuildConfig(b.allocator) catch |err| {
        std.debug.print("failed to parse `build_config.json`: {}\n", .{err});
        std.process.exit(1);
    };

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_module = b.addModule("gvca", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    for (build_config.add_include_paths) |include_path| {
        exe_module.addIncludePath(.{ .cwd_relative = include_path });
    }
    for (build_config.add_library_paths) |library_path| {
        exe_module.addLibraryPath(.{ .cwd_relative = library_path });
    }
    for (build_config.link_system_librarys) |system_library| {
        exe_module.linkSystemLibrary(system_library, .{});
    }
    exe_module.addImport("zargs", b.dependency("zargs", .{
        .target = target,
        .optimize = optimize,
    }).module("zargs"));

    const exe = b.addExecutable(.{
        .name = "gvca",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);
    run_exe.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_exe.addArgs(args);
    }
    const run_step = b.step("run", "Run the application");
    run_step.dependOn(&run_exe.step);

    const exe_check = b.addExecutable(.{ .name = "gvca", .root_module = exe_module });
    const check = b.step("check", "Check if gvca compiles");
    check.dependOn(&exe_check.step);

    const test_targets = [_]std.Target.Query{
        .{}, // native
    };
    const test_step = b.step("test", "Run unit tests");
    for (test_targets) |test_target| {
        const unit_tests = b.addTest(.{
            .root_module = exe_module,
            .target = b.resolveTargetQuery(test_target),
        });

        const run_unit_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_unit_tests.step);
    }
}
