//! 此阶段将分发包的各个文件转换为git hash blob，此外，最终将相同blob归并在一起。
const std = @import("std");
const vcaligner = @import("vcaligner");
const c = vcaligner.c_helper.c;
const analysis = @import("analysis.zig");

pub const CollectArtifactsBlobError = error{
    BadReleasePath,
    Unexpected,
};

pub fn collectArtifactsBlob(
    pool: *vcaligner.Pool,
    release_path: [:0]const u8,
    gpa: analysis.mainWorkerManagedGpa,
) !struct {
    analysis.release_artifact.PathDepot,
    analysis.release_artifact.Node.Depot,
    analysis.ReleaseArtifactBlobManifest.Building,
} {
    var release_artifact_paths_appending: analysis.release_artifact.PathDepot.PinnedAppending = .init(gpa);
    errdefer release_artifact_paths_appending.deinit();
    var node_depot_appending: analysis.release_artifact.Node.Depot.PinnedAppending = .init(gpa);
    errdefer node_depot_appending.deinit();
    var blob_agendas_building: analysis.ReleaseArtifactBlobManifest.Building = .{ .list = .empty };
    errdefer blob_agendas_building.deinit(gpa);
    var release_dir = try std.fs.cwd().openDirZ(release_path, .{ .iterate = true });
    defer release_dir.close();
    var wait_group: std.Thread.WaitGroup = .{};
    defer pool.waitAndWork(&wait_group);
    var walker = try release_dir.walk(gpa.allocator());
    walk: while (try walker.next()) |entry| {
        const kind: analysis.release_artifact.Kind = switch (@import("builtin").os.tag) {
            // NOTE: 本程序的分析模式当前仅仅支持linux操作（或许有其他posix操作系统，但当前没有准备测试，因此保守起见不支持），不会支持windows，理由如下：
            // 1. windows的文件是混淆大小写的。如果分发包实际是大小写敏感的而windows对此大小写不敏感，就可能导致路径分析问题。
            // 2. aux等特殊设备文件windows无法处理，linux可以。
            // 3. linux对于NTFS的符号链接解压所得的成更加一致的POSIX风格符号链接，windows对于NTFS的符号链接和linux的符号链接会有不同处理模式。
            // 虽然如果release包最初来自于release而开发者碰巧没有开`core.symlinks=true`的话，linux的处理风格会导致release和仓库内的解析结果不同。
            // 但是我们的处理方法本身就容忍解析结果不同，而windows并不能确定最好的处理方案，徒增烦恼。
            .linux => sw: switch (entry.kind) {
                // whiteout在容器的文件系统里常见，忽略即可。
                // 但是zig0.15.2的`nextLinux`内部实现似乎漏掉了`.whiteout`的可能性导致实际不可能出现（成为unknown)，这或许是个bug。
                .directory, .whiteout => continue :walk,
                // 下列文件类型有可能被打包者打包进去，但是git仓库里绝对不可能出现。跳过这些文件解析，因为它们的异常性，放出警告。
                inline .block_device, .character_device, .named_pipe => |kind| {
                    std.log.warn("Abnormal release artifact {s} of kind {s}.", .{ entry.path, @tagName(kind) });
                    continue :walk;
                },
                // 下列文件类型绝无可能被打包，如果解析得到此文件唯一可能是给的路径有问题。
                inline .unix_domain_socket => |kind| {
                    std.log.err("Bad release path. Wrong release artifact {s} of kind {s}", .{ entry.path, @tagName(kind) });
                    return CollectArtifactsBlobError.BadReleasePath;
                },
                // 0.15.2版本的zig在linux上的`nextLinux`内部实现决定了下面这两种类不可能出现。
                .door, .event_port => unreachable,
                .file => .file,
                .sym_link => .sym_link,
                // 在xfs等文件系统得到unknown可能是正常现象，需要再提取一次文件信息。
                .unknown => {
                    const stat = std.posix.fstatatZ(release_dir.fd, entry.path, std.posix.AT.SYMLINK_NOFOLLOW) catch |err| {
                        const src = @src();
                        std.log.err("{s} at {s} {s} line{d} path: {s}", .{ @errorName(err), src.file, src.fn_name, src.line, entry.path });
                        return err;
                    };
                    switch (stat.mode & std.posix.S.IFMT) {
                        std.posix.S.IFDIR => continue :sw .directory,
                        std.posix.S.IFLNK => continue :sw .sym_link,
                        std.posix.S.IFREG => continue :sw .file,
                        std.posix.S.IFBLK => continue :sw .block_device,
                        // 注意Whiteout也会走到这里
                        std.posix.S.IFCHR => continue :sw .character_device,
                        std.posix.S.IFIFO => continue :sw .named_pipe,
                        std.posix.S.IFSOCK => continue :sw .unix_domain_socket,
                        else => |unkown_mask| {
                            std.log.err("Unexpected st_mode mask {o}. Kernel corrupted.", .{unkown_mask});
                            return CollectArtifactsBlobError.Unexpected;
                        },
                    }
                },
            },
            else => @compileError("Only support linux system currently."),
        };
        const pi = try release_artifact_paths_appending.appendDupeZ(entry.path);
        const ni = try node_depot_appending.create();
        try blob_agendas_building.append(gpa, ni);
        const node = node_depot_appending.get(ni);
        node.* = .{ .path_key = pi, .blob_hash = undefined };
        pool.spawnWg(&wait_group, subTask, .{
            release_dir,
            release_artifact_paths_appending.get(pi),
            kind,
            &node.blob_hash,
        });
    }
    return .{
        release_artifact_paths_appending.toUnpinned(),
        node_depot_appending.toUnpinned(),
        blob_agendas_building,
    };
}

pub fn subTask(
    release_dir: std.fs.Dir,
    release_artifact_path: [:0]const u8,
    release_artifact_kind: analysis.release_artifact.Kind,
    blob_hash_out: *c.git_oid,
) void {
    var gpa_instance: vcaligner.gpa.Exclusive.Instance = .init();
    const gpa = gpa_instance.gpae();
    blob_hash_out.* = gitBlobSha1Hash(release_dir, release_artifact_path, release_artifact_kind, gpa.allocator) catch {
        vcaligner.crash_dump.dumpAndCrash(@src());
    };
}

fn gitBlobSha1Hash(
    dir: std.fs.Dir,
    path: [:0]const u8,
    kind: analysis.release_artifact.Kind,
    allocator: std.mem.Allocator,
) !c.git_oid {
    var hasher: std.crypto.hash.Sha1 = .init(.{});
    // 8192通常可以确保容纳所有路径长度（linux最大路径一般为4096），且本身也是一个比较合适的文件读取缓冲区节点，适用于计算hash。
    // 对于符号链接的场景，如果8192不够用，将动态在堆上反复分配直到够用为止。
    var buffer: [8192]u8 = undefined;
    switch (kind) {
        .sym_link => {
            var heap_buffer: []u8 = &.{};
            defer allocator.free(heap_buffer);
            const link = dir.readLinkZ(path, &buffer) catch |err| switch (err) {
                std.posix.ReadLinkError.NameTooLong => link: {
                    heap_buffer = try allocator.alloc(u8, buffer.len * 2);
                    retry_read_link: while (true) {
                        break :link dir.readLinkZ(path, heap_buffer) catch |e| switch (e) {
                            std.posix.ReadLinkError.NameTooLong => {
                                const new_heap_buffer_len = try std.math.mul(usize, heap_buffer.len, 2);
                                heap_buffer = try allocator.realloc(heap_buffer, new_heap_buffer_len);
                                continue :retry_read_link;
                            },
                            else => return e,
                        };
                    }
                },
                else => return err,
            };
            const prefix = try std.fmt.allocPrint(allocator, "blob {}\x00", .{link.len});
            defer allocator.free(prefix);
            hasher.update(prefix);
            hasher.update(link);
        },
        .file => {
            const file = try dir.openFileZ(path, .{});
            defer file.close();
            const file_size = try file.getEndPos();
            if (file_size == 0) return vcaligner.cli.ana_runner.empty_git_blob_sha1_hash;
            const prefix = try std.fmt.allocPrint(allocator, "blob {}\x00", .{file_size});
            defer allocator.free(prefix);
            hasher.update(prefix);
            while (true) {
                const bytes_read = try file.read(&buffer);
                if (bytes_read == 0) break;
                hasher.update(buffer[0..bytes_read]);
            }
        },
    }
    return .{ .id = hasher.finalResult() };
}
