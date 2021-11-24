const std = @import("std");
const fs = std.fs;
const fmt = std.fmt;
const assert = std.debug.assert;
const os = std.os;

// Example abilist path:
// ./sysdeps/unix/sysv/linux/aarch64/libc.abilist
const AbiList = struct {
    targets: []const ZigTarget,
    path: []const u8,
};
const ZigTarget = struct {
    arch: std.Target.Cpu.Arch,
    abi: std.Target.Abi,
};

// Symbol struct is used to define binary encoding of symbol mapping.
const Symbol = struct {
    name: []const u8,
    inclusions: std.ArrayList(SymbolInclusion),
};

// SymbolInclusion describes where this symbol can be found.
const SymbolInclusion = struct {
    // Multiple targets for current glibc version and lib combination.
    target_names: std.ArrayList([]const u8),

    // Multiple versions can have same symbol in same library.
    // Names are later converted to index based bitsets
    glibc_versions: std.ArrayList([]const u8),

    // lib is already an index from lib_names, so nothing has to be
    // done when writing to binary file.
    lib: usize,

    // Lowest glibc target version that this inclusion appears in
    // For example: pthread_sigmask was migrated from libpthread
    // to libc in glibc-2.32, so inclusion with libc would have
    // the index of glibc-2.32. 0 is default value for lower versions.
    since_version: u8 = 0,
};

const lib_names = [_][]const u8{
    "c",
    "dl",
    "m",
    "pthread",
    "rt",
    "ld",
    "util",
};

// fpu/nofpu are hardcoded elsewhere, based on .gnueabi/.gnueabihf with an exception for .arm
// n64/n32 are hardcoded elsewhere, based on .gnuabi64/.gnuabin32
const abi_lists = [_]AbiList{
    AbiList{
        .targets = &[_]ZigTarget{
            ZigTarget{ .arch = .aarch64, .abi = .gnu },
            ZigTarget{ .arch = .aarch64_be, .abi = .gnu },
        },
        .path = "aarch64",
    },
    AbiList{
        .targets = &[_]ZigTarget{ZigTarget{ .arch = .s390x, .abi = .gnu }},
        .path = "s390/s390-64",
    },
    AbiList{
        .targets = &[_]ZigTarget{
            ZigTarget{ .arch = .arm, .abi = .gnueabi },
            ZigTarget{ .arch = .armeb, .abi = .gnueabi },
            ZigTarget{ .arch = .arm, .abi = .gnueabihf },
            ZigTarget{ .arch = .armeb, .abi = .gnueabihf },
        },
        .path = "arm",
    },
    AbiList{
        .targets = &[_]ZigTarget{
            ZigTarget{ .arch = .sparc, .abi = .gnu },
            ZigTarget{ .arch = .sparcel, .abi = .gnu },
        },
        .path = "sparc/sparc32",
    },
    AbiList{
        .targets = &[_]ZigTarget{ZigTarget{ .arch = .sparcv9, .abi = .gnu }},
        .path = "sparc/sparc64",
    },
    AbiList{
        .targets = &[_]ZigTarget{
            ZigTarget{ .arch = .mips64el, .abi = .gnuabi64 },
            ZigTarget{ .arch = .mips64, .abi = .gnuabi64 },
        },
        .path = "mips/mips64",
    },
    AbiList{
        .targets = &[_]ZigTarget{
            ZigTarget{ .arch = .mips64el, .abi = .gnuabin32 },
            ZigTarget{ .arch = .mips64, .abi = .gnuabin32 },
        },
        .path = "mips/mips64",
    },
    AbiList{
        .targets = &[_]ZigTarget{
            ZigTarget{ .arch = .mipsel, .abi = .gnueabihf },
            ZigTarget{ .arch = .mips, .abi = .gnueabihf },
        },
        .path = "mips/mips32",
    },
    AbiList{
        .targets = &[_]ZigTarget{
            ZigTarget{ .arch = .mipsel, .abi = .gnueabi },
            ZigTarget{ .arch = .mips, .abi = .gnueabi },
        },
        .path = "mips/mips32",
    },
    AbiList{
        .targets = &[_]ZigTarget{ZigTarget{ .arch = .x86_64, .abi = .gnu }},
        .path = "x86_64/64",
    },
    AbiList{
        .targets = &[_]ZigTarget{ZigTarget{ .arch = .x86_64, .abi = .gnux32 }},
        .path = "x86_64/x32",
    },
    AbiList{
        .targets = &[_]ZigTarget{ZigTarget{ .arch = .i386, .abi = .gnu }},
        .path = "i386",
    },
    AbiList{
        .targets = &[_]ZigTarget{ZigTarget{ .arch = .powerpc64le, .abi = .gnu }},
        .path = "powerpc/powerpc64",
    },
    AbiList{
        .targets = &[_]ZigTarget{ZigTarget{ .arch = .powerpc64, .abi = .gnu }},
        .path = "powerpc/powerpc64",
    },
    AbiList{
        .targets = &[_]ZigTarget{
            ZigTarget{ .arch = .powerpc, .abi = .gnueabi },
            ZigTarget{ .arch = .powerpc, .abi = .gnueabihf },
        },
        .path = "powerpc/powerpc32",
    },
};

// glibc 2.31 added sysdeps/unix/sysv/linux/arm/le and sysdeps/unix/sysv/linux/arm/be
// Before these directories did not exist.
const ver30 = std.builtin.Version{
    .major = 2,
    .minor = 30,
};
// Similarly, powerpc64 le and be were introduced in glibc 2.29
const ver28 = std.builtin.Version{
    .major = 2,
    .minor = 28,
};

const FunctionSet = struct {
    list: std.ArrayList(VersionedFn),
    fn_vers_list: FnVersionList,
};
const FnVersionList = std.StringHashMap(std.ArrayList(usize));

const VersionedFn = struct {
    ver: []const u8, // example: "GLIBC_2.15"
    name: []const u8, // example: "puts"
};
const Function = struct {
    name: []const u8, // example: "puts"
    lib: []const u8, // example: "c"
    index: usize,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = &arena.allocator;
    const args = try std.process.argsAlloc(allocator);

    const abilist_dir = args[1]; // path to directory that contains abilist files for all glibc versions
    const zig_src_dir = args[2]; // path to the source checkout of zig, lib dir, e.g. ~/zig-src/lib

    const version_dir = try fs.cwd().openDir(abilist_dir, .{ .iterate = true });
    var version_dir_it = version_dir.iterate();

    // All symbols from glibc
    var all_symbols = std.StringHashMap(Symbol).init(allocator);
    var global_ver_set = std.StringHashMap(usize).init(allocator);

    var glibc_out_dir = try fs.path.join(allocator, &[_][]const u8{ zig_src_dir, "libc", "glibc" });

    // For each target - 7 library bitsets of available glibc versions.
    // Version names are converted to bitsets when writing binary file.
    // Target names (keys of StringHashMap) must be ordered in same order
    // as target_names section in binary file.
    var available_library_versions = std.StringHashMap([7]std.ArrayList([]const u8)).init(allocator);

    while (try version_dir_it.next()) |entry| {
        const version = try std.builtin.Version.parse(entry.name);
        const current_version_path = try fs.path.join(allocator, &[_][]const u8{ abilist_dir, entry.name });
        const prefix = try fs.path.join(allocator, &[_][]const u8{ current_version_path, "sysdeps", "unix", "sysv", "linux" });

        var global_fn_set = std.StringHashMap(Function).init(allocator);
        var target_functions = std.AutoHashMap(usize, FunctionSet).init(allocator);

        for (abi_lists) |*abi_list| {
            const target_funcs_gop = try target_functions.getOrPut(@ptrToInt(abi_list));
            if (!target_funcs_gop.found_existing) {
                target_funcs_gop.value_ptr.* = FunctionSet{
                    .list = std.ArrayList(VersionedFn).init(allocator),
                    .fn_vers_list = FnVersionList.init(allocator),
                };
            }
            const fn_set = &target_funcs_gop.value_ptr.list;

            // Generate list of target names for current abi_list
            var target_names = std.ArrayList([]const u8).init(allocator);
            for (abi_list.targets) |target| {
                const name = try std.fmt.allocPrint(allocator, "{s}-linux-{s}", .{ @tagName(target.arch), @tagName(target.abi) });
                try target_names.append(name);

                // Initialize library versions array list for current target
                var i:u8=0;
                var libs_version_list:[7]std.ArrayList([]const u8) = undefined;
                // loop for lib_names.len times
                while(i<7):(i+=1){
                    libs_version_list[i] = std.ArrayList([]const u8).init(allocator);
                }
                try available_library_versions.put(name, libs_version_list);
            }

            // Formatted with GLIBC_ prefix to be compatible with how versions are described in .abilist files.
            for (lib_names) |lib_name, lib_i| {
                const lib_prefix = if (std.mem.eql(u8, lib_name, "ld")) "" else "lib";
                const basename = try fmt.allocPrint(allocator, "{s}{s}.abilist", .{ lib_prefix, lib_name });
                const abi_list_filename = blk: {
                    const is_c = std.mem.eql(u8, lib_name, "c");
                    const is_m = std.mem.eql(u8, lib_name, "m");
                    const is_ld = std.mem.eql(u8, lib_name, "ld");
                    if (abi_list.targets[0].abi == .gnuabi64 and (is_c or is_ld)) {
                        break :blk try fs.path.join(allocator, &[_][]const u8{ prefix, abi_list.path, "n64", basename });
                    } else if (abi_list.targets[0].abi == .gnuabin32 and (is_c or is_ld)) {
                        break :blk try fs.path.join(allocator, &[_][]const u8{ prefix, abi_list.path, "n32", basename });
                    } else if (abi_list.targets[0].arch != .arm and
                        abi_list.targets[0].abi == .gnueabihf and
                        (is_c or (is_m and abi_list.targets[0].arch == .powerpc)))
                    {
                        break :blk try fs.path.join(allocator, &[_][]const u8{ prefix, abi_list.path, "fpu", basename });
                    } else if (abi_list.targets[0].arch != .arm and
                        abi_list.targets[0].abi == .gnueabi and
                        (is_c or (is_m and abi_list.targets[0].arch == .powerpc)))
                    {
                        break :blk try fs.path.join(allocator, &[_][]const u8{ prefix, abi_list.path, "nofpu", basename });
                    } else if ((abi_list.targets[0].arch == .armeb or abi_list.targets[0].arch == .arm) and version.order(ver30) == .gt) {
                        var le_be = "le";
                        if (abi_list.targets[0].arch == .armeb) {
                            le_be = "be";
                        }
                        break :blk try fs.path.join(allocator, &[_][]const u8{ prefix, abi_list.path, le_be, basename });
                    } else if ((abi_list.targets[0].arch == .powerpc64le or abi_list.targets[0].arch == .powerpc64) and version.order(ver28) == .gt) {
                        var le_be = "le";
                        if (abi_list.targets[0].arch == .powerpc64) {
                            le_be = "be";
                        }
                        break :blk try fs.path.join(allocator, &[_][]const u8{ prefix, abi_list.path, le_be, basename });
                    }

                    break :blk try fs.path.join(allocator, &[_][]const u8{ prefix, abi_list.path, basename });
                };
                const max_bytes = 10 * 1024 * 1024;
                const contents = std.fs.cwd().readFileAlloc(allocator, abi_list_filename, max_bytes) catch |err| {
                    std.debug.warn("unable to open {s}: {}\n", .{ abi_list_filename, err });
                    std.process.exit(1);
                };
                var lines_it = std.mem.tokenize(u8, contents, "\n");
                symbols: while (lines_it.next()) |line| {
                    var tok_it = std.mem.tokenize(u8, line, " ");
                    const ver = tok_it.next().?;
                    const name = tok_it.next().?;
                    const category = tok_it.next().?;
                    if (!std.mem.eql(u8, category, "F") and
                        !std.mem.eql(u8, category, "D"))
                    {
                        continue;
                    }
                    if (std.mem.startsWith(u8, ver, "GCC_")) continue;
                    try global_ver_set.put(ver, undefined);
                    const gop = try global_fn_set.getOrPut(name);
                    if (gop.found_existing) {
                        if (!std.mem.eql(u8, gop.value_ptr.lib, "c")) {
                            gop.value_ptr.lib = lib_name;
                        }
                    } else {
                        gop.value_ptr.* = Function{
                            .name = name,
                            .lib = lib_name,
                            .index = undefined,
                        };
                    }
                    try fn_set.append(VersionedFn{
                        .ver = ver,
                        .name = name,
                    });

                    // Append versions available for current lib to available_library_versions
                    for(target_names.items)|target_name|{
                        var alv_gop = try available_library_versions.getOrPut(target_name);
                        if(alv_gop.found_existing){
                            // lib_i must exist - otherwise something is definitely wrong.
                            // append unique versions only
                            var found = false;
                            for(alv_gop.value_ptr.*[lib_i].items) |version_string|{
                                if(std.mem.eql(u8, version_string, ver)){
                                    found = true;
                                    break;
                                }
                            }
                            if(!found){
                               try alv_gop.value_ptr.*[lib_i].append(ver);
                            }
                        }else{
                            std.debug.print("target: {s} not found \n", .{target_name});
                            return error.CorruptSymbolsFile;
                        }
                    }

                    const all_syms_gop = try all_symbols.getOrPut(name);
                    if (!all_syms_gop.found_existing) {
                        all_syms_gop.value_ptr.* = Symbol{
                            .name = name,
                            .inclusions = std.ArrayList(SymbolInclusion).init(allocator),
                        };
                    }
                    var s_inclusion = SymbolInclusion{
                        .target_names = std.ArrayList([]const u8).init(allocator),
                        .glibc_versions = std.ArrayList([]const u8).init(allocator),
                        .lib = lib_i,
                    };

                    // find if inclusion for current library already exists
                    if (all_syms_gop.value_ptr.*.inclusions.items.len > 0) {
                        for (all_syms_gop.value_ptr.*.inclusions.items) |*sym_inclusion| {
                            if (sym_inclusion.lib == lib_i) {
                                // append available targets to inclusion only if they are not already added
                                for (target_names.items) |target_name| {
                                    var found = false;
                                    for (sym_inclusion.*.target_names.items) |added_name| {
                                        if (std.mem.eql(u8, added_name, target_name)) {
                                            found = true;
                                            break;
                                        }
                                    }
                                    if (!found) {
                                        try sym_inclusion.*.target_names.append(target_name);
                                    }
                                }

                                // Append unique glibc versions to version list
                                var found = false;
                                for (sym_inclusion.*.glibc_versions.items) |glibc_version| {
                                    if (std.mem.eql(u8, glibc_version, ver)) {
                                        found = true;
                                        break;
                                    }
                                }
                                if (!found) {
                                    try sym_inclusion.*.glibc_versions.append(ver);
                                }

                                continue :symbols;
                            }
                        }
                    }
                    // if current lib does not exist in the list - add new inclusion
                    for (target_names.items) |target_name| {
                        try s_inclusion.target_names.append(target_name);
                        try s_inclusion.glibc_versions.append(ver);
                    }
                    try all_syms_gop.value_ptr.*.inclusions.append(s_inclusion);
                }
            }
        }

        const global_fn_list = blk: {
            var list = std.ArrayList([]const u8).init(allocator);
            var it = global_fn_set.keyIterator();
            while (it.next()) |key| try list.append(key.*);
            std.sort.sort([]const u8, list.items, {}, strCmpLessThan);
            break :blk list.items;
        };
        const global_ver_list = blk: {
            var list = std.ArrayList([]const u8).init(allocator);
            var it = global_ver_set.keyIterator();
            while (it.next()) |key| try list.append(key.*);
            std.sort.sort([]const u8, list.items, {}, versionLessThan);
            break :blk list.items;
        };
        {
            const vers_txt_path = try fs.path.join(allocator, &[_][]const u8{ glibc_out_dir, "vers.txt" });
            const vers_txt_file = try fs.cwd().createFile(vers_txt_path, .{});
            defer vers_txt_file.close();
            var buffered = std.io.bufferedWriter(vers_txt_file.writer());
            const vers_txt = buffered.writer();
            for (global_ver_list) |name, i| {
                global_ver_set.put(name, i) catch unreachable;
                try vers_txt.print("{s}\n", .{name});
            }
            try buffered.flush();
        }
        {
            const fns_txt_path = try fs.path.join(allocator, &[_][]const u8{ glibc_out_dir, "fns.txt" });
            const fns_txt_file = try fs.cwd().createFile(fns_txt_path, .{});
            defer fns_txt_file.close();
            var buffered = std.io.bufferedWriter(fns_txt_file.writer());
            const fns_txt = buffered.writer();
            for (global_fn_list) |name, i| {
                const value = global_fn_set.getPtr(name).?;
                value.index = i;
                try fns_txt.print("{s} {s}\n", .{ name, value.lib });
            }
            try buffered.flush();
        }

        // Now the mapping of version and function to integer index is complete.
        // Here we create a mapping of function name to list of versions.
        for (abi_lists) |*abi_list| {
            const value = target_functions.getPtr(@ptrToInt(abi_list)).?;
            const fn_vers_list = &value.fn_vers_list;
            for (value.list.items) |*ver_fn| {
                const gop = try fn_vers_list.getOrPut(ver_fn.name);
                if (!gop.found_existing) {
                    gop.value_ptr.* = std.ArrayList(usize).init(allocator);
                }
                const ver_index = global_ver_set.get(ver_fn.ver).?;
                if (std.mem.indexOfScalar(usize, gop.value_ptr.items, ver_index) == null) {
                    try gop.value_ptr.append(ver_index);
                }
            }
        }

        {
            const abilist_txt_path = try fs.path.join(allocator, &[_][]const u8{ glibc_out_dir, "abi.txt" });
            const abilist_txt_file = try fs.cwd().createFile(abilist_txt_path, .{});
            defer abilist_txt_file.close();
            var buffered = std.io.bufferedWriter(abilist_txt_file.writer());
            const abilist_txt = buffered.writer();

            // first iterate over the abi lists
            for (abi_lists) |*abi_list| {
                const fn_vers_list = &target_functions.getPtr(@ptrToInt(abi_list)).?.fn_vers_list;
                for (abi_list.targets) |target, it_i| {
                    if (it_i != 0) try abilist_txt.writeByte(' ');
                    try abilist_txt.print("{s}-linux-{s}", .{ @tagName(target.arch), @tagName(target.abi) });
                }
                try abilist_txt.writeByte('\n');
                // next, each line implicitly corresponds to a function
                for (global_fn_list) |name| {
                    const value = fn_vers_list.getPtr(name) orelse {
                        try abilist_txt.writeByte('\n');
                        continue;
                    };
                    for (value.items) |ver_index, it_i| {
                        if (it_i != 0) try abilist_txt.writeByte(' ');
                        try abilist_txt.print("{d}", .{ver_index});
                    }
                    try abilist_txt.writeByte('\n');
                }
            }
            try buffered.flush();
        }
    }

    // Write binary file
    const symbols_file_path = try fs.path.join(allocator, &[_][]const u8{ glibc_out_dir, "symbols" });
    const symbols_file = try fs.cwd().createFile(symbols_file_path, .{});
    const sorted_ver_list = blk: {
        var list = std.ArrayList([]const u8).init(allocator);
        var it = global_ver_set.keyIterator();
        while (it.next()) |key| try list.append(key.*);
        std.sort.sort([]const u8, list.items, {}, versionLessThan);
        break :blk list.items;
    };
    var buff = std.io.bufferedWriter(symbols_file.writer());
    var writer = buff.writer();

    // Bit flags based on index of glibc version in binary file
    var verlist_flags = std.StringHashMap(u64).init(allocator);
    // Bit flags based on index of target in binary file
    var target_name_flags = std.StringHashMap(u32).init(allocator);

    // Write version length byte and versions to binary file.
    // We assume that the number of versions does not exceed u8 size
    const verlist_length: u8 = @truncate(u8, global_ver_set.count());
    const verlist_length_bytes = std.mem.asBytes(&verlist_length);
    try writer.writeAll(verlist_length_bytes);
    for (sorted_ver_list) |version_string, version_string_i| {
        try writer.writeAll(version_string);
        try writer.writeByte('\n');

        // Generate bit flag
        try verlist_flags.put(version_string, std.math.shl(u64, 1, @intCast(u64, version_string_i)));
    }

    // Write target lenght byte and list of targets
    var targets_n: u8 = 0;
    var target_names = std.ArrayList([]const u8).init(allocator);
    for (abi_lists) |*abi_list| {
        for (abi_list.targets) |target| {
            targets_n += 1;
            const target_name = try std.fmt.allocPrint(allocator, "{s}-linux-{s}", .{ @tagName(target.arch), @tagName(target.abi) });
            try target_names.append(target_name);
        }
    }
    const targetlist_length_bytes = std.mem.asBytes(&targets_n);
    try writer.writeAll(targetlist_length_bytes);
    for (target_names.items) |target, target_i| {
        try writer.writeAll(target);
        try writer.writeByte('\n');
        try target_name_flags.put(target, std.math.shl(u32, 1, @intCast(u32, target_i)));
    }

    // write versions available in each library for each target
    var al_it = available_library_versions.iterator();
    // order how data is presented must match target_names
    var available_library_versions_ordered = try allocator.alloc([7]u64, targets_n);
    while(al_it.next())|target_libs_versions|{

        for(target_names.items)|target_name, index|{
            // get the index for current target being processed
            if(std.mem.eql(u8, target_name, target_libs_versions.key_ptr.*)){
                // init to 0 all values
                for(available_library_versions_ordered[index])|*lib_versions_bitset|{
                    lib_versions_bitset.* = 0;
                }

                // generate bitsets for each library
                for(target_libs_versions.value_ptr.*)|verlists, lib_i|{
                    for(verlists.items)|version|{
                        // version must exist
                        const ver_bitflag = verlist_flags.get(version) orelse unreachable;
                        available_library_versions_ordered[index][lib_i] |= ver_bitflag;
                    }
                }
            }
        }
    }
    for(available_library_versions_ordered)|versions_in_lib_bitsets|{
        for(versions_in_lib_bitsets)|version_bitset|{
            const bytes_to_write = std.mem.asBytes(&version_bitset);
            try writer.writeAll(bytes_to_write);
        }
    }
    available_library_versions.deinit();

    // Write all_symbols information
    var all_syms_it = all_symbols.iterator();
    while (all_syms_it.next()) |symbol| {
        // Write symbol name with a null character
        try writer.writeAll(symbol.value_ptr.*.name);
        try writer.writeByte(0x00);

        for (symbol.value_ptr.*.inclusions.items) |inclusion, inclusion_i| {
            var targets_bitmask: u32 = 0;
            var verlist_bitmask: u64 = 0;

            // Create bitmask for target
            for (inclusion.target_names.items) |target_name| {
                const bits = target_name_flags.get(target_name);
                if (bits) |b| {
                    targets_bitmask |= b;
                }
            }
            // Last inclusion indicator - 1 << 31 bit set for target bitmask
            if (inclusion_i == symbol.value_ptr.*.inclusions.items.len - 1) {
                targets_bitmask |= 1 << 31;
            }
            // Write target bitmask
            const targets_bitmask_bytes = std.mem.asBytes(&targets_bitmask);
            try writer.writeAll(targets_bitmask_bytes);

            // Create bitmask for glibc version
            for (inclusion.glibc_versions.items) |version| {
                const bits = verlist_flags.get(version);
                if (bits) |b| {
                    verlist_bitmask |= b;
                }
            }
            // Write glibc version bitmask
            const verlist_bitmask_bytes = std.mem.asBytes(&verlist_bitmask);
            try writer.writeAll(verlist_bitmask_bytes);

            // Write lib index as a single byte from a known list (lib_names)
            const lib_index_bytes = std.mem.asBytes(&@intCast(u8, inclusion.lib));
            try writer.writeAll(lib_index_bytes);
        }
    }

    // Flush buffer after everything was written
    try buff.flush();
}

pub fn strCmpLessThan(context: void, a: []const u8, b: []const u8) bool {
    _ = context;
    return std.mem.order(u8, a, b) == .lt;
}

pub fn versionLessThan(context: void, a: []const u8, b: []const u8) bool {
    _ = context;
    const sep_chars = "GLIBC_.";
    var a_tokens = std.mem.tokenize(u8, a, sep_chars);
    var b_tokens = std.mem.tokenize(u8, b, sep_chars);

    while (true) {
        const a_next = a_tokens.next();
        const b_next = b_tokens.next();
        if (a_next == null and b_next == null) {
            return false; // equal means not less than
        } else if (a_next == null) {
            return true;
        } else if (b_next == null) {
            return false;
        }
        const a_int = fmt.parseInt(u64, a_next.?, 10) catch unreachable;
        const b_int = fmt.parseInt(u64, b_next.?, 10) catch unreachable;
        if (a_int < b_int) {
            return true;
        } else if (a_int > b_int) {
            return false;
        }
    }
}
