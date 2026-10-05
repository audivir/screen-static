# screen-static

Portable builds of [GNU Screen](https://www.gnu.org/software/screen/) with ncurses (and, for
glibc, libxcrypt) linked in statically, built with [zig](https://ziglang.org) as the C toolchain.

- Linux glibc: only glibc is linked dynamically, and only symbols up to glibc 2.17, so the
  binaries run on anything from CentOS 7 onwards
- Linux musl (`--static`): fully static, no runtime dependencies at all (e.g. Alpine)
- macOS: only libSystem and libpam are dynamic (both ship with macOS, which has no fully static
  binaries)

Common terminal descriptions (xterm, xterm-256color, screen, screen-256color, tmux, tmux-256color,
linux, vt100, vt220, rxvt, alacritty, kitty, foot, wezterm, ...) are compiled into ncurses, so
screen works even on systems without a terminfo database. The system database is still used
first, from `/etc/terminfo`, `/lib/terminfo`, `/usr/share/terminfo`, and `/usr/lib/terminfo`, or
from `$TERMINFO`, `$TERMINFO_DIRS`, and `~/.terminfo`.

PAM is only enabled on macOS, since on Linux it would be a dynamic dependency. Without PAM, screen
checks passwords (`lockscreen`, password-protected multiuser attach) against `/etc/shadow`, which
only works when the binary is installed setuid root. utmp support is disabled, so screen windows
do not appear in `who`.

## Prerequisites

- `zig`, GNU make (the `make` 3.81 of macOS is enough), `perl`, `git`
- `autoconf`, `automake`, `libtool` (the git trees of screen and libxcrypt ship no `configure`
  script)
- On macOS: Xcode Command Line Tools (SDK)

## Installation

Clone the repo with submodules (shallow, the history of the vendored projects is not needed):

```shell
git clone --recurse-submodules --shallow-submodules https://github.com/audivir/screen-static
cd screen-static
```

## Usage

```shell
./build.sh
```

This builds ncurses (and libxcrypt on Linux glibc) from `vendor/` as static libraries, then
builds screen against them. Output is installed under `dist/`:

- `dist/bin/screen`: the binary; copy it anywhere on your `PATH`
- `dist/share/man/man1/screen.1`: the man page
- `dist/share/screen`: an example `screenrc` and the tables for converting legacy character
  sets (e.g. KOI8-R, EUC-JP) to UTF-8; their path is compiled in as
  `/usr/local/share/screen/utf8encodings`, so when installing elsewhere, add
  `screenencodings <prefix>/share/screen/utf8encodings` to `~/.screenrc`

Pass `--static` for the fully static musl build on Linux (output in `dist-static/`), `--clean` to
remove previous build output first, and `--jobs N` to control parallelism.

To run the smoke tests against the build:

```shell
./tests/run_smoke_tests.sh            # dist/
./tests/run_smoke_tests.sh --static   # dist-static/
```

## Releases

Publishing a GitHub release tagged with the screen version (e.g. `v5.0.2`, matching the tag
checked out in `vendor/screen`) builds and attaches `screen-static-<platform>.tar.gz` for
`macos-arm64`, `linux-amd64`, `linux-arm64`, `linux-musl-amd64`, and `linux-musl-arm64`, together
with the sources they were built from (`screen-static-sources.tar.gz`).

To update a vendored project, check out a new release tag in its submodule and commit it, e.g.
`git -C vendor/screen fetch --depth 1 origin tag v.5.0.3 && git -C vendor/screen checkout v.5.0.3`.

## Acknowledgments

This repository builds and vendors the following upstream projects, unmodified, as git
submodules under `vendor/`. Credit goes to their respective authors:

- [GNU Screen](https://www.gnu.org/software/screen/) by the Free Software Foundation and
  contributors
- [ncurses](https://invisible-island.net/ncurses/) by Thomas E. Dickey and the Free Software
  Foundation
- [libxcrypt](https://github.com/besser82/libxcrypt) by Thorsten Kukuk, Björn Esser, Zack Weinberg,
  and contributors (Linux glibc builds only)

## License

MIT for the code in this repository. See `NOTICE` for the licenses of the upstream projects and the
resulting binaries, which are GPL-3.0-or-later (screen).
