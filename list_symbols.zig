const std = @import("std");
const reader = @import("glibc_symbols_reader.zig");

const lib_names = [_][]const u8{
    "c",
    "dl",
    "m",
    "pthread",
    "rt",
    "ld",
    "util",
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = &arena.allocator;
    var file = try std.fs.cwd().openFile("libc/glibc/symbols", .{});
    var result = try reader.readSymbolsFile(allocator, file);

    for (result.symbols.items) |symbol| {
        std.debug.print("Symbol: {s} in lib{s} \n", .{ symbol.name, symbol.lib });

        std.debug.print("\t Available versions: ", .{});
        for (symbol.versions.items) |version| {
            std.debug.print("{s} ", .{version});
        }
        std.debug.print("\n", .{});

        std.debug.print("\t Available targets: ", .{});
        for (symbol.targets.items) |target| {
            std.debug.print("{s} ", .{target});
        }
        std.debug.print("\n\n", .{});
    }

    // List version for each lib in each target
    var it = result.versions_in_libs.iterator();
    while(it.next())|entry|{
        std.debug.print("Target: {s} \n", .{entry.key_ptr.*});
        for(entry.value_ptr.*)|libs_versions, lib_i|{
            std.debug.print("\t versions available in lib{s}: ", .{lib_names[lib_i]});
            for(libs_versions.items)|version_index|{
                std.debug.print("{d} ", .{version_index});
            }
            std.debug.print("\n", .{});
        }
    }
}
