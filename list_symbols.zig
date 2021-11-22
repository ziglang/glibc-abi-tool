const std = @import("std");
const reader = @import("glibc_symbols_reader.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = &arena.allocator;
    var file = try std.fs.cwd().openFile("libc/glibc/symbols", .{});
    var symbols = try reader.readSymbolsFile(allocator, file);

    for (symbols.items) |symbol| {
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
}
