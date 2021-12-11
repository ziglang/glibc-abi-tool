# glibc ABI Tool

This repository contains `.abilist` files from glibc. These files are used to
generate symbol mapping files that are used with Zig to target any version of
glibc.

## Adding new glibc version `.abilist` files

1. Clone glibc

```sh
git clone git://sourceware.org/git/glibc.git
```

2. Check out the new glibc version git tag, e.g. `glibc-2.34`.

3. Run the tool to grab the new abilist files:

```sh
zig run collect_abilist_files.zig -- $GLIBC_GIT_REPO_PATH
```

4. This mirrors the directory structure into the `glibc` subdirectory,
   namespaced under the version number, but only copying files with the
   .abilist extension.

5. Inspect the changes and then commit these new files into git.

## Updating .abilist symbols file for zig

1. Run `update_glibc.zig` at the root of this repo

```
zig run update_glibc.zig -- glibc/ path/to/zig/lib
```

symbol mapping files will be updated in `path/to/zig/lib/libc/glibc`.

## Binary encoding format:

- 1 byte - number of glibc versions
- ordered list of glibc versions terminated by newline byte
- 1 byte - number of targets
- ordered list of targets terminated by newline byte
- number of targets amount of entries x 7 (one entry for each library). Each entry is:
  - u64 (8 bytes) bit set for versions available in library for that particular target.
  - in total this is 56 bytes (7x8) per each target
- list of symbols:
  - null terminated symbol name
  - list of inclusions
    - u32 (4 bytes) bitset for targets (1 << (INDEX_IN_TARGET_LIST))
      - last inclusion is indicated if 1 << 31 bit is set in target bitset
    - u64 (8 bytes) glibc version bitset (1 << (INDEX_IN_GLIBC_VERSION_LIST))
    - u8 (1 byte) library index from a known library names list

## List all symbols with their library, targets and versions in current symbols file

```bash
zig run list_symbols.zig
```
