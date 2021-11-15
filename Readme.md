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
