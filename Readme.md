# About

This repository contains `.abilist` files from glibc. These files are used to generate symbol mapping files that are used with [zig cc](https://andrewkelley.me/post/zig-cc-powerful-drop-in-replacement-gcc-clang.html)

## Adding new glibc version `.abilist` files

1. Clone glibc

```bash
git clone git://sourceware.org/git/glibc.git
```

2. Add new version to `TARGET_VERSIONS` tuple in `import_glibc_abilist.py`

3. Run `import_glibc_abilist.py`

```bash
import_glibc_abilist.py path/to/glibc/repo
```

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
- list of symbols:
  - null terminated symbol name
  - list of inclusions
    - u32 (4 bytes) bitset for targets (1 << (INDEX_IN_TARGET_LIST))
      - last inclusion is indicated if 1 << 31 bit is set in target bitset
    - u64 (8 bytes) glibc version bitset (1 << (INDEX_IN_GLIBC_VERSION_LIST))
    - u8 (1 byte) library index from a known library names list
