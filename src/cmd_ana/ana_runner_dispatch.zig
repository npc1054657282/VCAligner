const std = @import("std");
const zargs = @import("zargs");
const vcaligner = @import("vcaligner");
const diag = vcaligner.diag;
const cli = vcaligner.cli;

const cmd_config: cli.CommandConfig = cli.Runner.cmd_config;
pub const sub_cmd_name = "ana";
pub const cmd = blk: {
    @setEvalBranchQuota(4096);
    break :blk cli.Runner.Global.sharedArgs(zargs.Command.new(sub_cmd_name))
        .arg(zargs.Arg.optArg("rocksdb_path", []const u8).long("rocksdb-path").help(
            \\Path to the target RocksDB database. Must be set. 
        ++ cli.helpLastLine(cmd_config) ++
            \\
        ))
        .arg(zargs.Arg.optArg("release_path", []const u8).long("release-path").help(
            \\Path to the released package. Must be set. 
        ++ cli.helpLastLine(cmd_config) ++
            \\
        ))
        .arg(zargs.Arg.optArg("report_output", ?[]const u8).long("report-output").short('o').help(
            \\Output file path for the analysis report.
        ++ cli.helpLastLine(cmd_config) ++
            \\
        ))
        .arg(zargs.Arg.optArg("point_lookup_cache_mb", u64).long("point-lookup-cache-mb").default(512).help(
            \\Sets the point lookup cache mb for RocksDB read.
        ++ cli.helpLastLine(cmd_config) ++
            \\
        ))
        .arg(zargs.Arg.optArg("jobs", ?usize).short('j').long("jobs").help(
            \\Number of analysis worker threads. 
        ++ cli.helpNewLine(cmd_config) ++
            \\(Note: Does not include RocksDB background I/O threads).
        ++ cli.helpLastLine(cmd_config) ++
            \\
        ))
        .arg(zargs.Arg.optArg("strategy", enum { strict, topology }).long("strategy").default(.strict).help(
            \\Set the alignment resolution strategy for mapping release
        ++ cli.helpNewLine(cmd_config) ++
            \\artifacts to historical commits.
        ++ cli.helpNewLine(cmd_config) ++
            \\strict:
        ++ cli.helpNewLine(cmd_config) ++
            \\Fast, rigid exact-path matching. Assumes the release structure
        ++ cli.helpNewLine(cmd_config) ++
            \\perfectly mirrors the repository (or the specified --package-directory).
        ++ cli.helpNewLine(cmd_config) ++
            \\topology:
        ++ cli.helpNewLine(cmd_config) ++
            \\Advanced, content-first topology inference. Dynamically resolves
        ++ cli.helpNewLine(cmd_config) ++
            \\complex directory refactorings or monorepo structural shifts,
        ++ cli.helpNewLine(cmd_config) ++
            \\but incurs higher computational and memory overhead.
        ++ cli.helpLastLine(cmd_config) ++
            \\
        ))
        .arg(zargs.Arg.optArg("package_directory", ?[]const u8).long("package-directory").help(
            \\Specify the base directory of the package within the repository
        ++ cli.helpNewLine(cmd_config) ++
            \\when using the 'strict' strategy. Essential for aligning monorepo artifacts.
        ++ cli.helpNewLine(cmd_config) ++
            \\Completely IGNORED when using '--strategy topology'.
        ++ cli.helpLastLine(cmd_config) ++
            \\
        ))
        .config(cmd_config);
};

pub fn initFromArgs(args: cmd.Result(), allocator: std.mem.Allocator) !cli.Runner {
    return switch (args.strategy) {
        .strict => @import("AnaStrictRunner.zig").initFromArgs(args, allocator),
        .topology => @import("AnaTopologyRunner.zig").initFromArgs(args, allocator),
    };
}
