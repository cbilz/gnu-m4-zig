const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;
const PatchDir = @This();
const LazyPath = std.Build.LazyPath;
const Step = std.Build.Step;
const Allocator = mem.Allocator;
const DirActionIterator = @import("DirActionIterator.zig");

step: Step,
generated_directory: std.Build.GeneratedFile,
source_directory: LazyPath,
patches: []const Patch,

pub const base_id: Step.Id = .custom;

pub const Options = struct {
    source_directory: LazyPath,
    patches: []const Patch,
    first_ret_addr: ?usize = null,
};

pub const Patch = struct {
    file: LazyPath,
    source_path: DirActionIterator.SourcePath = .{ .count = 0 },
};

pub fn create(owner: *std.Build, options: Options) *PatchDir {
    const arena = owner.allocator;

    const name = owner.fmt("patching directory {s}", .{options.source_directory.getDisplayName()});

    const patches = arena.alloc(Patch, options.patches.len) catch @panic("OOM");
    for (options.patches, patches) |source, *target| {
        target.* = .{
            .file = source.file.dupe(owner),
            .source_path = switch (source.source_path) {
                .strip_dir_count => |n| .{ .strip_dir_count = n },
                .strip_dir_all => .{.strip_dir_all},
                .explicit => |p| .{ .explicit = owner.dupe(p) },
            },
        };
    }

    const patch_dir = arena.create(PatchDir) catch @panic("OOM");
    patch_dir.* = .{
        .step = Step.init(.{
            .id = base_id,
            .name = name,
            .owner = owner,
            .makeFn = make,
            .first_ret_addr = options.first_ret_addr orelse @returnAddress(),
        }),
        .generated_directory = .{ .step = &patch_dir.step },
        .source_directory = options.source_directory.dupe(owner),
        .patches = patches,
    };

    patch_dir.source_directory.addStepDependencies(&patch_dir.step);
    for (patch_dir.patches) |patch| patch.file.addStepDependencies(&patch_dir.step);

    return patch_dir;
}

pub fn getOutput(patch: *PatchDir) LazyPath {
    return .{ .generated = .{ .file = &patch.output_file } };
}

fn make(step: *Step, options: Step.MakeOptions) !void {
    _ = options;
    const b = step.owner;
    const arena = b.allocator;
    const patch_dir: *PatchDir = @fieldParentPtr("step", step);

    step.clearWatchInputs();
    var man = b.graph.cache.obtain();
    defer man.deinit();

    // Random bytes to make PatchDir unique. Refresh this with new
    // random bytes when PatchDir implementation is modified in a
    // non-backwards-compatible way.
    man.hash.add(@as(u32, 0x990db558));

    const src_cache_path = patch_dir.source_directory.getPath3(b, step);
    const src_dir_open = src_cache_path.openDir(".", .{ .iterate = true }) catch |err| {
        return step.fail("unable to open source directory '{}': {s}", .{
            src_cache_path, @errorName(err),
        });
    };
    defer src_dir_open.close();

    const Location = struct {
        old: enum { src, tmp, gen },
        new: enum { src, tmp, gen, del },
    };
    var files = std.StringArrayHashMapUnmanaged(Location){};

    {
        const need_derived_inputs = try step.addDirectoryWatchInput(patch_dir.source_directory);
        var it = try src_dir_open.walk(arena);
        defer it.deinit();
        while (try it.next()) |entry| {
            switch (entry.kind) {
                .directory => {
                    if (need_derived_inputs) {
                        const cache_path = try src_cache_path.join(arena, entry.path);
                        try step.addDirectoryWatchInputFromPath(cache_path);
                    }
                },
                .file => {
                    try files.put(arena, b.dupe(entry.path), .{ .old = .src, .new = .gen });
                },
                else => continue,
            }
        }
    }

    // Add files to manifest after sorting, which avoids unnecessary rebuilds when the directory is
    // subsequently traversed in a different order.
    {
        const Context = struct {
            fs: std.StringArrayHashMapUnmanaged(void),

            fn lessThan(self: @This(), lhs: usize, rhs: usize) bool {
                const lhs_path = self.fs.keys[lhs];
                const rhs_path = self.fs.keys[rhs];
                const len = @min(lhs_path.len, rhs_path.len);
                for (lhs_path[0..len], rhs_path[0..len]) |x, y| {
                    if (x < y) return true;
                    if (x > y) return false;
                }
                return lhs_path.len < rhs_path.len;
            }
        };
        files.sortUnstable(Context{ .fs = files });
        for (files.keys) |path| {
            const cache_path = try src_cache_path.join(arena, path);
            _ = try man.addFilePath(cache_path, null);
        }
    }

    for (patch_dir.patches) |patch| {
        const cache_path = patch.file.getPath3(b, step);
        _ = try man.addFilePath(cache_path, null);

        man.hash.add(@intFromEnum(patch.source_path));
        switch (patch.source_path) {
            .strip_dir_count => |c| man.hash.add(c),
            .strip_dir_all => man.hash.add(0),
            .explicit => |p| man.hash.addBytes(p),
        }

        try step.addWatchInput(patch.file);
    }

    if (try step.cacheHit(&man)) {
        const digest = man.final();
        patch_dir.generated_directory.path = try b.cache_root.join(arena, &.{ "o", &digest });
        return;
    }

    const gen_sub_path = blk: {
        const digest = man.final();
        break :blk b.pathJoin(&.{ "o", &digest });
    };

    // TODO: Who is supposed to take care of cleanup in case this build step fails?

    var gen_dir_open = b.cache_root.handle.makeOpenPath(gen_sub_path, .{}) catch |err| {
        return step.fail(
            "unable to make path '{}{s}': {s}",
            .{ b.cache_root, gen_sub_path, @errorName(err) },
        );
    };
    defer gen_dir_open.close();

    const tmp_sub_path = blk: {
        var random_bytes: [12]u8 = undefined;
        std.crypto.random.bytes(&random_bytes);
        var sub_path: [16]u8 = undefined;
        _ = std.fs.base64_encoder.encode(&sub_path, &random_bytes);
        break :blk "tmp.".* ++ sub_path;
    };

    {
        var tmp_dir_open = try gen_dir_open.makeOpenPath(&tmp_sub_path, .{});
        defer tmp_dir_open.close();

        for (patch_dir.patches) |patch| {
            const patch_cache_path = patch.file.getPath3(b, step);
            const patch_file_open = patch_cache_path.openFile(".", .{}) catch |err| {
                return step.fail(
                    "unable to open patch file '{}{s}': {s}",
                    .{ patch_cache_path.root_dir, patch_cache_path.sub_path, @errorName(err) },
                );
            };
            defer patch_file_open.close();
            const patch_reader = std.io.bufferedReader(patch_file_open.reader());
        }

        var it = files.iterator();
        while (it.next()) |entry| {
            assert(entry.value_ptr.old == entry.value_ptr.new);
            const file_dir_open = switch (entry.value_ptr.old) {
                .src => src_dir_open,
                .tmp => tmp_dir_open,
                .gen => continue,
            };
            const file_sub_path = entry.key_ptr.*;
            std.fs.Dir.copyFile(
                file_dir_open,
                file_sub_path,
                gen_dir_open,
                file_sub_path,
                .{},
            ) catch |err| {
                return step.fail("unable to copy file from '{}{s}' to '{}{s}': {s}", .{
                    file_dir_open,
                    file_sub_path,
                    gen_dir_open,
                    file_sub_path,
                    @errorName(err),
                });
            };
        }
    }

    try gen_dir_open.deleteTree(tmp_sub_path);

    patch_dir.generated_directory.path = try b.cache_root.join(arena, &.{gen_sub_path});
    try step.writeManifest(&man);
}

const Position = struct { line: u64, column: u64 };

fn PositionTrackingReader(Reader: type) type {
    return struct {
        inner: Reader,
        position: Position = .{ .line = 0, .column = 0 },
        prev_length: u64 = 0,

        pub const Error = Reader.Error;
        pub const Reader = std.io.Reader(*@This(), Error, read);

        pub fn read(self: *@This(), buf: []u8) Error!usize {
            const amt = try self.inner.read(buf);

            var length_offset = self.position.column;
            self.position.column += amt;

            var pos: usize = 0;
            while (std.mem.indexOfScalarPos(u8, buf[0..amt], pos, '\n')) |pos_newline| {
                self.position.line += 1;
                self.position.column = amt - pos_newline - 1;
                self.prev_length = pos_newline - pos + length_offset + 1;
                length_offset = 0;
                pos = pos_newline + 1;
            }
            return amt;
        }

        pub fn reader(self: *@This()) Reader {
            return .{ .context = self };
        }

        pub fn lastReadPosition(self: Self) Position {
            assert(line != 0 or column != 0);
            if (column != 0) {
                return .{
                    .line = self.position.line,
                    .column = self.position.line - 1,
                };
            } else {
                return .{
                    .line = self.position.line - 1,
                    .column = self.prev_length - 1,
                };
            }
        }
    };
}
