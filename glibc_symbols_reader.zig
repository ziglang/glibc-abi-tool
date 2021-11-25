const std = @import("std");

pub const ReaderError = error{
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

pub const Symbol = struct {
    name: []const u8,
    versions: std.ArrayList([]const u8),
    targets: std.ArrayList([]const u8),
    lib: []const u8,
};

pub const Result = struct{
    all_versions: std.ArrayList([]const u8),
    all_targets: std.ArrayList([]const u8),

    // There might be different versions available (from abilist files)
    // for same symbol in same library on different targets.
    // Structure:
    //  keys - target name strings
    //  values - 7 (for each known library from lib_names) lists of indexes from all_versions.
    // Version indexes are guaranteed to be sorted in ascending order.
    versions_in_libs: std.StringHashMap([7]std.ArrayList(u8)),

    symbols: std.ArrayList(Symbol),
};

pub fn readSymbolsFile(allocator: *std.mem.Allocator, symbols_file: std.fs.File) !Result {
    // First byte tells how many glibc versions there are
    var versions_number_byte: [1]u8 = undefined;
    _ = try symbols_file.readAll(&versions_number_byte);
    var versions_number = versions_number_byte[0];

    // Collect available glibc versions
    var all_versions = std.ArrayList([]const u8).init(allocator);
    var bitflag_verlist = std.AutoArrayHashMap(u64, []const u8).init(allocator);
    var i: u8 = 0;
    while (i < versions_number) {
        const version_bitflag = std.math.shl(u64, 1, @intCast(u64, i));
        const version_name = try readString(allocator, '\n', symbols_file);
        try all_versions.append(version_name);
        try bitflag_verlist.put(version_bitflag, version_name);
        i += 1;
    }

    // First byte after glibc version list is the number of targets
    var targets_number_byte: [1]u8 = undefined;
    _ = try symbols_file.readAll(&targets_number_byte);
    var targets_number = targets_number_byte[0];

    // Collect available targets
    var all_targets = std.ArrayList([]const u8).init(allocator);
    var bitflags_targetlist = std.AutoArrayHashMap(u32, []const u8).init(allocator);
    i = 0;
    while (i < targets_number): (i += 1) {
        const target_bitflag = std.math.shl(u32, 1, @intCast(u32, i));
        const target_name = try readString(allocator, '\n', symbols_file);
        try all_targets.append(target_name);
        try bitflags_targetlist.put(target_bitflag, target_name);
    }

    // Read available version bitsets in each library for each target
    i = 0;
    var versions_in_libs = std.StringHashMap([7]std.ArrayList(u8)).init(allocator);
    while(i<targets_number): (i+=1){
        var versions_in_libs_bytes: [56]u8 = undefined;
        _ = try symbols_file.readAll(&versions_in_libs_bytes);
        var versions_in_libs_current_target = std.mem.bytesToValue([7]u64, &versions_in_libs_bytes);

        const target_name = all_targets.items[i];
        var version_indexes:[7]std.ArrayList(u8) = undefined;

        for(versions_in_libs_current_target)|version_bitset, lib_i|{
            version_indexes[lib_i] = std.ArrayList(u8).init(allocator);

            var bv_it = bitflag_verlist.iterator();
            while(bv_it.next())|entry|{
                if(version_bitset & entry.key_ptr.* > 0){
                    // we have a string, but want an index for compactness
                    for(all_versions.items)|version_string, version_index|{
                        if(std.mem.eql(u8, version_string, entry.value_ptr.*)){

                            // we are sure that number of different glibc versions
                            // does not exceed u8 size.
                            try version_indexes[lib_i].append(@truncate(u8, version_index));
                        }
                    }
                }
            }
        }

        // version_indexes is sorted as we check from smallest to largets index
        try versions_in_libs.put(target_name, version_indexes);
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
            // Add available targets
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
            // Add available glibc versions
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

    return Result{
        .all_versions = all_versions,
        .all_targets = all_targets,
        .versions_in_libs = versions_in_libs,
        .symbols = symbols,
    };
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
