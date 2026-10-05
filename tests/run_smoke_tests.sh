#!/usr/bin/env bash
# Usage: ./tests/run_smoke_tests.sh [--static] [--dist DIR]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="$ROOT_DIR/dist"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --static)
      DIST="$ROOT_DIR/dist-static"
      shift
      ;;
    --dist)
      DIST="$(cd "$2" && pwd)"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

SCREEN="$DIST/bin/screen"
TMP="$(mktemp -d)"
export HOME="$TMP/home" SCREENDIR="$TMP/sockets" SHELL=/bin/sh
mkdir -p "$HOME" "$SCREENDIR"
chmod 700 "$SCREENDIR"
: >"$HOME/.screenrc"
cleanup() {
  "$SCREEN" -S outer -X quit >/dev/null 2>&1 || true
  "$SCREEN" -S smoke -X quit >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

pass() { echo "ok: $*"; }
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
# polls `screen -ls` for session NAME for up to 10 seconds.
wait_listed() {
  for _ in $(seq 50); do
    { "$SCREEN" -ls 2>/dev/null || true; } | grep -q "$1" && return 0
    sleep 0.2
  done
  return 1
}

version="$("$SCREEN" --version)"
echo "$version" | grep -q '^Screen version ' || fail "screen --version"
pass "$version"

# drives a detached session through -X commands.
"$SCREEN" -dmS smoke
wait_listed smoke || fail "session not listed by screen -ls"
# shellcheck disable=SC2016 # expanded by the shell inside screen.
"$SCREEN" -S smoke -X stuff 'echo hello-$((6*7))\n'
for _ in $(seq 50); do
  "$SCREEN" -S smoke -X hardcopy "$TMP/smoke.txt"
  grep -q hello-42 "$TMP/smoke.txt" 2>/dev/null && break
  sleep 0.2
done
grep -q hello-42 "$TMP/smoke.txt" || fail "command output missing from hardcopy"
"$SCREEN" -S smoke -X screen -t second
"$SCREEN" -S smoke -Q title | grep -q second || fail "second window"
"$SCREEN" -S smoke -X quit
pass "detached session, stuff, hardcopy, windows, quit"

# attaches a client inside a window of another screen with no terminfo database reachable,
# so the inner client must draw with the entries compiled into ncurses.
"$SCREEN" -dmS outer -T xterm-256color
"$SCREEN" -S outer -X stuff "TERMINFO=/nonexistent TERMINFO_DIRS=/nonexistent TERM=xterm-256color $SCREEN -S inner\n"
wait_listed inner || fail "inner session did not start"
# shellcheck disable=SC2016
"$SCREEN" -S inner -X stuff 'echo inner-$((6*7))\n'
for _ in $(seq 50); do
  "$SCREEN" -S outer -X hardcopy "$TMP/outer.txt"
  grep -q inner-42 "$TMP/outer.txt" 2>/dev/null && break
  sleep 0.2
done
grep -q inner-42 "$TMP/outer.txt" || fail "attached client did not draw (terminfo fallback)"
"$SCREEN" -S inner -X quit
"$SCREEN" -S outer -X quit
pass "attached client with built-in terminfo"

if [ "$(uname -s)" = Linux ] && ! LC_ALL=C grep -a -q 'ld-musl' "$SCREEN"; then
  max="$(LC_ALL=C grep -aoh 'GLIBC_2\.[0-9]*' "$SCREEN" | sort -uV | tail -n 1)" || true
  if [ -n "$max" ]; then
    [ "$(printf '%s\n' "$max" GLIBC_2.17 | sort -V | tail -n 1)" = GLIBC_2.17 ] \
      || fail "needs $max, newer than GLIBC_2.17"
    pass "glibc floor ($max)"
  fi
fi

echo "all smoke tests passed"
