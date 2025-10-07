add_rules("mode.valgrind", "mode.release")
-- libgit2使用链接例外规则，因此虽然是GPL2.0，但是本项目仅仅链接，所以不受它的传染性影响。
set_policy("check.target_package_licenses", false)

set_toolchains("@zig")

add_repositories("gvca-repo repo", {rootdir = os.scriptdir()})

add_requires("libgit2 v1.9.1+xdiff_without_regexp")
add_requires("rocksdb v10.5.1", {configs = {lz4 = true}})

rule("zig.build")
    on_config(function (target)
        -- 在调用 zig build 之前，获取所有依赖的路径
        local requires = target:get("requires")
        local includedirs = {}
        local linkdirs = {}
        local syslinks = {}
        for _, pkg in pairs(target:pkgs()) do
            table.join2(includedirs, path.join(pkg:installdir(), "include"))
            table.join2(includedirs, pkg:get("includedirs"))
            table.join2(linkdirs, pkg:get("linkdirs"))
            table.join2(syslinks, pkg:get("syslinks"))
            table.join2(syslinks, pkg:get("links"))
        end
        local config_editor = import("xmake_modules.jsonc")("build_config.json")
        config_editor:set("add_include_paths", jsonc.array(includedirs))
        config_editor:set("add_library_paths", jsonc.array(linkdirs))
        config_editor:set("link_system_librarys", jsonc.array(syslinks))
        config_editor:save()
        -- 设置testArgs参数
        local vscsetting_editor = import("xmake_modules.jsonc")(".vscode/settings.json")
        local zig_test_args = {"build", "test", "-Dtest_filter=${filter}"}
        vscsetting_editor:set("zig.testArgs", jsonc.array(zig_test_args))
        vscsetting_editor:save()
    end)
    on_build(function (target)
        local build_args = {"build", "-Doptimize=" .. (is_mode("release") and "ReleaseFast" or "Debug")}
        -- 执行 zig build
        os.execv("zig", build_args)
    end)

target("git-version-commit-aligner-zig")
    set_kind("phony")
    add_packages("libgit2")
    add_packages("lz4")
    add_packages("rocksdb")
    add_rules("zig.build")
