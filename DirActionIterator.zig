const std = @import("std");
const assert = std.debug.assert;

const SourcePathTag = enum(u1) {
    strip_dir_count = 0,
    strip_dir_all = 1,
    explicit = 2,
};
const SourcePath = union(SourcePathTag) {
    strip_dir_count: usize,
    strip_dir_all,
    explicit: []const u8,
};

const DirActionIterator = struct {
    allocator: std.mem.Allocator,
    patch: []const u8,
    source_path: SourcePath,
    pos: usize = 0,
    transaction_mode: ?TransactionMode = null,
    strings: std.ArrayListUnmanaged(u8) = .{},
    modified_paths: std.StringArrayHashMapUnmanaged(void) = .{},
    diagnostic: std.ArrayListUnmanaged(u8) = .{},

    const TransactionMode = enum { file, dir };

    const Self = @This();

    fn init(
        allocator: std.mem.Allocator,
        patch: []const u8,
        source_path: SourcePath,
    ) Self {
        return .{
            .allocator = allocator,
            .patch = patch,
            .source_path = source_path,
        };
    }

    fn deinit(it: *Self) void {
        it.strings.deinit();
        it.modified_paths.deinit();
        it.diagnostic.deinit();
        it.* = undefined;
    }

    fn next(it: *Self) ?FileActionIterator {
        return if (it.pos < it.patch.len) .{ .parent = it } else null;
    }

    const FileActionIterator = struct {
        parent: *Self,

        fn failWithExpectedLines(it: *@This(), expected_lines: []const []const u8) !void {
            assert(expected_lines.len >= 1);
            const p = it.parent;
            const patch = p.patch;
            const pos = p.pos;
            const n = indexOfNextLinePos(patch, pos) orelse patch.len;

            try p.diagnostic.appendSlice(p.allocator, if (expected_lines.len == 1)
                "\n======== expected this line: =========\n"
            else
                "\n==== expected any of these lines: ====\n");

            for (expected_lines) |line| {
                assert(indexOfNextLine(line) == null);
                try p.diagnostic.appendSlice(line);
                try p.diagnostic.append('\n');
            }

            try p.diagnostic.appendSlice(
                p.allocator,
                "\n======== instead found this: =========\n",
            );

            try p.diagnostic.appendSlice(patch[pos..n]);
            if (patch[n] != '\n') {
                try p.diagnostic.append('\n');
            }

            try p.diagnostic.appendSlice(
                p.allocator,
                "\n======================================\n",
            );

            return error.Error;
        }

        const prefixes = .{
            .old_mode = "old mode ",
            .new_mode = "new mode ",
            .deleted = "deleted file mode ",
            .new = "new file mode ",
            .copy_to = "copy to ",
            .copy_from = "copy from ",
            .rename_to = "rename to ",
            .rename_from = "rename from ",
        };

        fn next(it: *@This()) !?FileAction {
            const patch = it.parent.patch;
            const pos = &it.parent.pos;
            assert(pos.* == 0 or patch[pos.* - 1] == '\n');
            line_loop: while (true) {
                const prefix_git = "diff --git ";
                const prefix_unified = "--- ";
                const prefix_context = "*** ";
                if (startsWith(patch[pos.*..], prefix_git)) {
                    const i = std.mem.indexOfScalarPos(u8, patch, pos.*, '\n') orelse patch.len;
                    pos.* = i;
                    const combined_paths = patch[pos.* + prefix_git.len .. i];

                    var result = GitResult{};

                    header: while (indexOfNextLinePos(patch, pos.* +| 1)) |n| {
                        pos.* = n + 1;
                        const line = patch[pos.*..];

                        inline for (&values(TagEnum(GitResult))) |tag| {
                            switch (tag) {
                                .old_mode, .new_mode, .deleted, .new => {
                                    if (try it.setMode(&result, line, tag)) continue :header;
                                },
                                .copy_from, .copy_to, .rename_from, .rename_to => {
                                    if (try it.setPath(&result, line, tag)) continue :header;
                                },
                                .similarity, .dissimilarity => {
                                    if (try it.setPercentage(&result, line, tag)) continue :header;
                                },
                                .index => {
                                    if (try it.setIndex(&result, line)) continue :header;
                                },
                            }
                        }

                        if (startsWith(line, "--- ")) {
                            // TODO
                        } else {
                            // TODO
                        }
                    } else {
                        // TODO
                    }
                } else if (startsWith(patch[pos.*..], "--- ")) {
                    // TODO
                } else if (startsWith(patch[pos.*..], "*** ")) {
                    // TODO
                }
            }
        }

        fn setMode(
            it: *@This(),
            result: *GitResult,
            line: []const u8,
            comptime tag: TagEnum(GitResult),
        ) !bool {
            const prefix = @field(prefixes, @tagName(tag));
            const postfixes = .{
                .normal = "100644",
                .executable = "100755",
            };

            if (result.allows(tag) and startsWith(line, prefix)) {
                inline for (values(GitResult.Mode)) |mode| {
                    if (startsWith(line[prefix.len..], @field(postfixes, @tagName(mode)) ++ "\n")) {
                        @field(result, @tagName(tag)) = mode;
                        return true;
                    }
                }
                const expected_lines = comptime blk: {
                    var lines: [valueCount(GitResult.Mode)][]const u8 = undefined;
                    for (values(GitResult.Mode), 0..) |mode, i| {
                        lines[i] = prefix ++ @field(postfixes, @tagName(mode));
                    }
                    break :blk lines;
                };
                return it.failWithExpectedLines(&expected_lines);
            }

            return false;
        }
    };

    const FileAction = union(enum) {
        delete: File,
        create: Create,
        edit: Edit,

        const File = struct {
            path: []const u8,
            is_executable: ?bool,
        };

        const Create = struct {
            file: File,
            hunks: []const u8,

            fn apply(hunk: @This(), writer: anytype) !void {}
        };

        const Edit = struct {
            old_file: File,
            new_file: File,
            delete_old_file: bool,
            hunks: []const u8,
            format: Format,

            const Format = enum { git, unified, context };

            fn apply(hunk: @This(), writer: anytype) !void {
                switch (hunk) {
                    .git => |git| try git.apply(writer),
                    .unified => |unified| try unified.apply(writer),
                    .context => |context| try context.apply(writer),
                }
            }
        };
    };
};

fn startsWith(haystack: []const u8, needle: []const u8) bool {
    return std.mem.startsWith(u8, haystack, needle);
}

fn indexOfNextLine(slice: []const u8) ?usize {
    return indexOfNextLinePos(slice, 0);
}

fn indexOfNextLinePos(slice: []const u8, start_index: usize) ?usize {
    if (std.mem.indexOfScalarPos(u8, slice, start_index, '\n')) |i| {
        return i + 1;
    } else return null;
}

const GitResult = struct {
    old_mode: ?Mode = null,
    new_mode: ?Mode = null,
    deleted: ?Mode = null,
    new: ?Mode = null,
    copy_from: ?[]const u8 = null,
    copy_to: ?[]const u8 = null,
    rename_from: ?[]const u8 = null,
    rename_to: ?[]const u8 = null,
    similarity: ?u8 = null,
    dissimilarity: ?u8 = null,
    index: ?Index = null,

    const Self = @This();
    const Mode = enum { normal, executable };
    const Index = struct {
        old_hash: []const u8,
        new_hash: []const u8,
        mode: ?Mode,
    };

    fn allows(result: Self, comptime field: TagEnum(Self)) bool {
        return @field(result, @tagName(field)) == null and switch (field) {
            .deleted, .new => result.action() == .unknown,
            .copy_from, .copy_to => switch (result.action()) {
                .copy, .copy_or_rename, .unknown => true,
                else => false,
            },
            .rename_from, .rename_to => switch (result.action()) {
                .rename, .copy_or_rename, .unknown => true,
                else => false,
            },
            .old_mode,
            .new_mode,
            .similarity,
            .dissimilarity,
            .index,
            => switch (result.action()) {
                .copy, .rename, .copy_or_rename, .unknown => true,
                .deleted, .new => false,
            },
        };
    }

    fn action(result: Self) Action {
        if (result.deleted != null) {
            return .deleted;
        }
        if (result.new != null) {
            return .new;
        }
        if (result.copy_from != null or result.copy_to != null) {
            return .copy;
        }
        if (result.rename_from != null or result.rename_to != null) {
            return .rename;
        }
        if (result.old_mode != null or result.new_mode != null or
            result.similarity != null or result.dissimilarity != null or
            result.index != null)
        {
            return .copy_or_rename;
        }
        return .unknown;
    }
    const Action = enum { deleted, new, copy, rename, copy_or_rename, unknown };
};

fn TagEnum(Struct: type) type {
    const struct_fields = @typeInfo(Struct).@"struct".fields;
    var fields: [struct_fields.len]std.builtin.Type.EnumField = undefined;
    for (struct_fields, &fields, 0..) |source, *target, n| {
        target.* = .{ .name = source.name, .value = n };
    }
    return @Type(.{ .@"enum" = .{
        .tag_type = std.math.IntFittingRange(0, fields.len -| 1),
        .fields = fields,
        .is_exhaustive = true,
    } });
}

fn valueCount(Enum: type) comptime_int {
    return @typeInfo(Enum).@"enum".fields.len;
}

fn values(Enum: type) [valueCount(Enum)]Enum {
    const fields = @typeInfo(Enum).@"enum".fields;
    var result: [fields.len]Enum = undefined;
    for (fields, &result) |field, *value| {
        value.* = @field(Enum, field.name);
    }
    return result;
}
