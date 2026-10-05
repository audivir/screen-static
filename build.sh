#!/usr/bin/env bash
# Usage: ./build.sh [--jobs N] [--clean] [--static]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
CLEAN=0
STATIC=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobs)
      JOBS="$2"
      shift 2
      ;;
    --clean)
      CLEAN=1
      shift
      ;;
    --static)
      STATIC=1
      shift
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

GLIBC_VER=2.17

# terminal entries compiled into ncurses, used when the system terminfo database lacks them.
FALLBACKS=(
  ansi dumb linux vt100 vt220
  xterm xterm-256color xterm-color
  screen screen-256color screen.xterm-256color
  tmux tmux-256color
  rxvt rxvt-256color
  alacritty kitty foot wezterm
)
TERMINFO_DIRS_DEFAULT=/etc/terminfo:/lib/terminfo:/usr/share/terminfo:/usr/lib/terminfo:/usr/share/lib/terminfo

OS="$(uname -s)"
ARCH="$(uname -m)"
[ "$ARCH" = arm64 ] && ARCH=aarch64

SUFFIX=""
[ "$STATIC" = 1 ] && SUFFIX="-static"
WORK="$ROOT_DIR/build$SUFFIX"
PREFIX="$WORK/deps"
HOST="$WORK/host"
DIST="$ROOT_DIR/dist$SUFFIX"

case "$OS-$ARCH" in
  Linux-x86_64 | Linux-aarch64)
    ZIG_TARGET=$ARCH-linux-gnu.$GLIBC_VER
    [ "$STATIC" = 1 ] && ZIG_TARGET=$ARCH-linux-musl
    ;;
  Darwin-aarch64 | Darwin-x86_64)
    ZIG_TARGET=native
    ;;
  *)
    echo "unsupported host $OS-$ARCH" >&2
    exit 1
    ;;
esac
if [ "$OS" != Linux ] && [ "$STATIC" = 1 ]; then
  echo "--static is only supported on Linux" >&2
  exit 1
fi

MAKE="${MAKE:-$(command -v gmake || command -v make)}"
"$MAKE" --version 2>/dev/null | grep -q 'GNU Make' || {
  echo "GNU make required" >&2
  exit 1
}

if [ "$ZIG_TARGET" = native ]; then export CC="zig cc"; else export CC="zig cc -target $ZIG_TARGET"; fi
export AR="zig ar"
export RANLIB="zig ranlib"
[ "$OS" = Linux ] && export LD="zig ld.lld"

if [ "$CLEAN" = 1 ]; then
  echo ">>> cleaning $WORK and $DIST"
  rm -rf "$WORK" "$DIST"
fi
mkdir -p "$WORK/src" "$PREFIX/include" "$PREFIX/lib"

cd "$WORK/src"

prepare() {
  [ -d "$1" ] && return
  if [ ! -f "$ROOT_DIR/vendor/$1/.git" ] && [ ! -d "$ROOT_DIR/vendor/$1/.git" ]; then
    echo "vendor/$1 is missing, run: git submodule update --init --depth 1" >&2
    exit 1
  fi
  echo ">>> preparing $1 ($(git -C "$ROOT_DIR/vendor/$1" describe --tags 2>/dev/null || echo unknown))"
  cp -R "$ROOT_DIR/vendor/$1" "$1"
  rm -rf "$1/.git"
}

# zig ships no libcrypt for glibc targets, while musl and macOS provide crypt() in libc.
NEED_XCRYPT=0
[ "$OS" = Linux ] && [ "$STATIC" = 0 ] && NEED_XCRYPT=1

prepare ncurses
[ "$NEED_XCRYPT" = 1 ] && prepare libxcrypt
prepare screen

NCURSES_COMMON=(
  --without-shared --with-normal --without-debug
  --without-cxx --without-cxx-binding --without-ada
  --without-tests --without-manpages
  --enable-widec --disable-db-install
)

# builds tic and infocmp for the build machine to compile the fallback entries.
if [ ! -x "$HOST/bin/infocmp" ]; then
  echo ">>> ncurses (host tic/infocmp)"
  rm -rf ncurses-host
  cp -R ncurses ncurses-host
  (
    cd ncurses-host
    ./configure --prefix="$HOST" "${NCURSES_COMMON[@]}" --with-progs
    "$MAKE" -j"$JOBS"
    "$MAKE" install.progs
  )
fi

echo ">>> ncurses"
(
  cd ncurses
  [ -f Makefile ] && "$MAKE" distclean >/dev/null 2>&1 || true
  ./configure \
    --prefix="$PREFIX" \
    "${NCURSES_COMMON[@]}" \
    --without-progs --with-termlib \
    --with-default-terminfo-dir=/usr/share/terminfo \
    --with-terminfo-dirs="$TERMINFO_DIRS_DEFAULT" \
    --with-fallbacks="$(
      IFS=,
      echo "${FALLBACKS[*]}"
    )" \
    --with-tic-path="$HOST/bin/tic" \
    --with-infocmp-path="$HOST/bin/infocmp"
  "$MAKE" -j"$JOBS" libs
  "$MAKE" install.libs
)

SCREEN_LIBS="-ltinfow"
if [ "$NEED_XCRYPT" = 1 ]; then
  echo ">>> libxcrypt"
  (
    cd libxcrypt
    [ -f configure ] || autoreconf -fi >/dev/null
    ./configure \
      --prefix="$PREFIX" \
      --disable-shared --enable-static \
      --disable-obsolete-api --disable-xcrypt-compat-files --disable-werror \
      --enable-hashes=all
    "$MAKE" -j"$JOBS"
    "$MAKE" install-libLTLIBRARIES install-nodist_includeHEADERS
  )
fi

echo ">>> screen"
(
  cd screen/src
  [ -f configure ] || autoreconf -fi >/dev/null
  LDFLAGS="-s -L$PREFIX/lib"
  [ "$STATIC" = 1 ] && LDFLAGS="-static $LDFLAGS"
  # libpam ships with macOS but would be a dynamic dependency on Linux.
  # utmp needs a setuid binary.
  PAM=--disable-pam
  [ "$OS" = Darwin ] && PAM=--enable-pam
  ./configure \
    --prefix=/usr/local \
    "$PAM" --disable-utmp --enable-telnet \
    CFLAGS="-Os" CPPFLAGS="-I$PREFIX/include" LDFLAGS="$LDFLAGS" LIBS="$SCREEN_LIBS"
  # pins the build date to the vendored commit for reproducible builds.
  SOURCE_DATE_EPOCH="$(git -C "$ROOT_DIR/vendor/screen" log -1 --format=%ct)" "$MAKE" -j"$JOBS" screen
  rm -rf "$DIST"
  mkdir -p "$DIST/bin" "$DIST/share/man/man1" "$DIST/share/screen"
  cp screen "$DIST/bin/screen"
  cp doc/screen.1 "$DIST/share/man/man1/"
  cp -R utf8encodings "$DIST/share/screen/"
  cp etc/screenrc "$DIST/share/screen/screenrc.example"
)

SCREEN_BIN="$DIST/bin/screen"
echo
echo ">>> done: $SCREEN_BIN"
"$SCREEN_BIN" --version
if [ "$OS" = Linux ]; then
  if [ "$STATIC" = 1 ]; then
    # static musl libc embeds the loader path as a string, so check for an interpreter header.
    if readelf -l "$SCREEN_BIN" | grep -q INTERP; then
      echo "WARNING: screen references a dynamic loader, not fully static" >&2
    else
      echo "fully static"
    fi
  elif LC_ALL=C grep -a -q -E 'lib(ncurses|tinfo|crypt|pam|utempter)[a-z]*\.so' "$SCREEN_BIN"; then
    echo "WARNING: screen links a dependency dynamically, not only glibc" >&2
  else
    echo "only glibc is dynamic"
  fi
else
  otool -L "$SCREEN_BIN"
fi
