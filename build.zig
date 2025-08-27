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

fn createGvcaModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    build_config: *const BuildConfig,
    comptime is_test: bool,
) *std.Build.Module {
    // 如果有可能需要导出的模块，利用`is_test`参数决定是创建导出模块还是创建匿名模块（若用于测试，则创建匿名模块）。
    // 由于没有需要导出的模块，此参数未使用。
    _ = is_test;
    const mpsc_queue_module = b.createModule(.{
        .root_source_file = b.path("src/mpsc_queue.zig"),
        .target = target,
        .optimize = optimize,
    });
    const mpsc_queue_options = b.addOptions();
    mpsc_queue_options.addOption(bool, "enable_sequence_type_override_warning", true);
    mpsc_queue_options.addOption(bool, "enable_small_object_warning", true);
    mpsc_queue_options.addOption(?bool, "runtime_safety", null);
    mpsc_queue_module.addOptions("mpsc_queue_options", mpsc_queue_options);

    const gvca_module = b.createModule(.{
        .root_source_file = b.path("src/gvca.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    for (build_config.add_include_paths) |include_path| {
        gvca_module.addIncludePath(.{ .cwd_relative = include_path });
    }
    for (build_config.add_library_paths) |library_path| {
        gvca_module.addLibraryPath(.{ .cwd_relative = library_path });
    }
    for (build_config.link_system_librarys) |system_library| {
        gvca_module.linkSystemLibrary(system_library, .{});
    }

    gvca_module.addImport("gvca", gvca_module);

    gvca_module.addImport("mpsc_queue", mpsc_queue_module);

    gvca_module.addImport("zargs", b.dependency("zargs", .{
        .target = target,
        .optimize = optimize,
    }).module("zargs"));
    return gvca_module;
}

pub fn build(b: *std.Build) void {
    const build_config = readBuildConfig(b.allocator) catch |err| {
        std.debug.print("failed to parse `build_config.json`: {}\n", .{err});
        std.process.exit(1);
    };

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_module = createGvcaModule(
        b,
        target,
        optimize,
        &build_config,
        false,
    );

    const exe = b.addExecutable(.{
        .name = "gvca",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    const docs_step = b.step("doc", "Emit documentation");
    const docs_install = b.addInstallDirectory(.{
        .install_dir = .prefix,
        .install_subdir = "docs",
        .source_dir = exe.getEmittedDocs(),
    });
    docs_step.dependOn(&docs_install.step);
    b.getInstallStep().dependOn(docs_step);

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

    const test_filters: []const []const u8 = b.option(
        []const []const u8,
        "test_filter",
        "Skip tests that do not match any of the specified filters",
    ) orelse &.{};
    const test_targets = [_]std.Target.Query{
        .{}, // native
    };
    const test_step = b.step("test", "Run unit tests");
    for (test_targets) |test_target| {
        const unit_tests = b.addTest(.{
            .root_module = createGvcaModule(
                b,
                b.resolveTargetQuery(test_target),
                optimize,
                &build_config,
                true,
            ),
            .filters = test_filters,
        });

        const run_unit_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_unit_tests.step);
    }
}
