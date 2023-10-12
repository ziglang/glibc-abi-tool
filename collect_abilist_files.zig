const std = @import("std");
const Target = std.Target;
const mem = std.mem;
const log = std.log;
const fs = std.fs;

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const args = try std.process.argsAlloc(arena);
    const glibc_src_path = args[1];

    const stdout = try exec(arena, &.{ "git", "-C", glibc_src_path, "describe", "--tags" });
    if (!mem.startsWith(u8, stdout, "glibc-")) {
        fatal("the git repository provided does not have an official glibc release tag checked out. git describe returned '{s}'", .{stdout});
    }
    const ver_text = mem.trimRight(u8, stdout["glibc-".len..], " \n\r");
    const ver = Version.parse(ver_text) catch |err| {
        fatal("unable to parse '{s}': {s}", .{ ver_text, @errorName(err) });
    };
    const search_dir_path = try fs.path.join(arena, &.{ glibc_src_path, "sysdeps" });
    const dest_dir_path = try std.fmt.allocPrint(arena, "glibc/{d}.{d}/sysdeps", .{
        ver.major, ver.minor,
    });

    var dest_dir = try std.fs.cwd().makeOpenPath(dest_dir_path, .{});
    defer dest_dir.close();

    var glibc_src_dir = try std.fs.cwd().openIterableDir(search_dir_path, .{});
    defer glibc_src_dir.close();

    var walker = try glibc_src_dir.walk(arena);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (!std.mem.endsWith(u8, entry.basename, ".abilist"))
            continue;

        if (fs.path.dirname(entry.path)) |dirname| {
            try dest_dir.makePath(dirname);
        }
        try glibc_src_dir.dir.copyFile(entry.path, dest_dir, entry.path, .{});
    }
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    log.err(format, args);
    std.process.exit(1);
}

fn exec(arena: mem.Allocator, argv: []const []const u8) ![]const u8 {
    const child_result = try std.ChildProcess.exec(.{
        .allocator = arena,
        .argv = argv,
        .max_output_bytes = 200 * 1024 * 1024,
    });
    if (child_result.stderr.len != 0) {
        fatal("{s}", .{child_result.stderr});
    }

    switch (child_result.term) {
        .Exited => |code| if (code == 0) return child_result.stdout else {
            fatal("{s} exited with code {d}", .{ argv[0], code });
        },
        else => {
            fatal("{s} crashed", .{argv[0]});
        },
    }
}

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32 = 0,

    pub const Range = struct {
        min: Version,
        max: Version,

        pub fn includesVersion(self: Range, ver: Version) bool {
            if (self.min.order(ver) == .gt) return false;
            if (self.max.order(ver) == .lt) return false;
            return true;
        }

        /// Checks if system is guaranteed to be at least `version` or older than `version`.
        /// Returns `null` if a runtime check is required.
        pub fn isAtLeast(self: Range, ver: Version) ?bool {
            if (self.min.order(ver) != .lt) return true;
            if (self.max.order(ver) == .lt) return false;
            return null;
        }
    };

    pub fn order(lhs: Version, rhs: Version) std.math.Order {
        if (lhs.major < rhs.major) return .lt;
        if (lhs.major > rhs.major) return .gt;
        if (lhs.minor < rhs.minor) return .lt;
        if (lhs.minor > rhs.minor) return .gt;
        if (lhs.patch < rhs.patch) return .lt;
        if (lhs.patch > rhs.patch) return .gt;
        return .eq;
    }

    pub fn parse(text: []const u8) !Version {
        var end: usize = 0;
        while (end < text.len) : (end += 1) {
            const c = text[end];
            if (!std.ascii.isDigit(c) and c != '.') break;
        }
        // found no digits or '.' before unexpected character
        if (end == 0) return error.InvalidVersion;

        var it = std.mem.splitScalar(u8, text[0..end], '.');
        // substring is not empty, first call will succeed
        const major = it.first();
        if (major.len == 0) return error.InvalidVersion;
        const minor = it.next() orelse "0";
        // ignore 'patch' if 'minor' is invalid
        const patch = if (minor.len == 0) "0" else (it.next() orelse "0");

        return Version{
            .major = try std.fmt.parseUnsigned(u32, major, 10),
            .minor = try std.fmt.parseUnsigned(u32, if (minor.len == 0) "0" else minor, 10),
            .patch = try std.fmt.parseUnsigned(u32, if (patch.len == 0) "0" else patch, 10),
        };
    }

    pub fn format(
        self: Version,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        out_stream: anytype,
    ) !void {
        _ = options;
        if (fmt.len == 0) {
            if (self.patch == 0) {
                if (self.minor == 0) {
                    return std.fmt.format(out_stream, "{d}", .{self.major});
                } else {
                    return std.fmt.format(out_stream, "{d}.{d}", .{ self.major, self.minor });
                }
            } else {
                return std.fmt.format(out_stream, "{d}.{d}.{d}", .{ self.major, self.minor, self.patch });
            }
        } else {
            std.fmt.invalidFmtError(fmt, self);
        }
    }
};
