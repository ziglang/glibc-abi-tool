const std = @import("std");

const ReaderError = error{
    CorruptSymbolsFile,
};

const LAST_INCLUSION: u32 = std.math.shl(u32, 1, 31);

const lib_names = [_][]const u8{
    "c",
    "dl",
    "m",
    "pthread",
    "rt",
    "ld",
    "util",
};

const Symbol = struct {
    name: []const u8,
    versions: std.ArrayList([]const u8),
    targets: std.ArrayList([]const u8),
    lib: []const u8,
};

pub fn main() !void {
    var symbols = try readSymbolsFile("libc/glibc/symbols");

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

pub fn readSymbolsFile(file_path: []const u8) !std.ArrayList(Symbol) {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = &arena.allocator;

    const symbols_file = try std.fs.cwd().openFile(file_path, .{});

    // First byte tells how many glibc versions there are
    var versions_number_byte: [1]u8 = undefined;
    _ = try symbols_file.readAll(&versions_number_byte);
    var versions_number = versions_number_byte[0];

    // Collect available glibc versions
    var bitflag_verlist = std.AutoArrayHashMap(u64, []const u8).init(allocator);
    var i: u8 = 0;
    while (i < versions_number) {
        const version_bitflag = std.math.shl(u64, 1, @intCast(u64, i));
        const version_name = try readString(allocator, '\n', symbols_file);
        try bitflag_verlist.put(version_bitflag, version_name);
        i += 1;
    }

    // First byte after glibc version list is the number of targets
    var targets_number_byte: [1]u8 = undefined;
    _ = try symbols_file.readAll(&targets_number_byte);
    var targets_number = targets_number_byte[0];

    // Collect available targets
    var bitflags_targetlist = std.AutoArrayHashMap(u32, []const u8).init(allocator);
    i = 0;
    while (i < targets_number) {
        const target_bitflag = std.math.shl(u32, 1, @intCast(u32, i));
        const target_name = try readString(allocator, '\n', symbols_file);
        try bitflags_targetlist.put(target_bitflag, target_name);
        i += 1;
    }

    var symbols = std.ArrayList(Symbol).init(allocator);

    // Collect symbols information
    while (true) {
        const symbol_name: []const u8 = try readString(allocator, 0x00, symbols_file);
        if (symbol_name.len == 0) {
            break;
        }

        // Collect all inclusions per library
        while (true) {
            var symbol = Symbol{
                .targets = std.ArrayList([]const u8).init(allocator),
                .versions = std.ArrayList([]const u8).init(allocator),
                .name = symbol_name,
                .lib = undefined,
            };

            var read_length: usize = 0;
            // 4 bytes for targets bitset
            var target_bitset_bytes: [4]u8 = undefined;
            read_length = try symbols_file.readAll(&target_bitset_bytes);
            if (read_length != 4) {
                return error.CorruptSymbolsFile;
            }
            const target_bitset = std.mem.bytesToValue(u32, &target_bitset_bytes);
            // Check which targets are available
            var bt_it = bitflags_targetlist.iterator();
            while (bt_it.next()) |entry| {
                if (target_bitset & entry.key_ptr.* > 0) {
                    try symbol.targets.append(entry.value_ptr.*);
                }
            }

            // 8 bytes for glibc versions bitset
            var version_bitset_bytes: [8]u8 = undefined;
            read_length = try symbols_file.readAll(&version_bitset_bytes);
            if (read_length != 8) {
                return error.CorruptSymbolsFile;
            }
            const version_bitset = std.mem.bytesToValue(u64, &version_bitset_bytes);
            // Check which glibc versions are available
            var bv_it = bitflag_verlist.iterator();
            while (bv_it.next()) |entry| {
                if (version_bitset & entry.key_ptr.* > 0) {
                    try symbol.versions.append(entry.value_ptr.*);
                }
            }

            // 1 byte for library index
            var library_index_byte: [1]u8 = undefined;
            read_length = try symbols_file.readAll(&library_index_byte);
            if (read_length != 1) {
                return error.CorruptSymbolsFile;
            }
            const library_index = library_index_byte[0];
            symbol.lib = lib_names[library_index];

            try symbols.append(symbol);
            if (target_bitset & LAST_INCLUSION > 0) {
                break;
            }
        }
    }

    return symbols;
}

// Reads file until delimiter is found and returns read string.
pub fn readString(allocator: *std.mem.Allocator, delimeter: u8, file: std.fs.File) ![]const u8 {
    var buff = std.ArrayList(u8).init(allocator);
    while (true) {
        var byte: [1]u8 = undefined;
        var bytes_read = try file.read(&byte);
        if (bytes_read != 1) {
            return "";
        }
        if (byte[0] == delimeter) {
            return buff.toOwnedSlice();
        }
        try buff.append(byte[0]);
    }
}
