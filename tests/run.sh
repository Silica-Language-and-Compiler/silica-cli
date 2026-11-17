#!/usr/bin/env bash
# End-to-end tests for the silica CLI. Runs against a real compiler: the one in
# $SILICA_HOME/bin (downloaded on first use) or $SILICA_COMPILER.
#
#   tests/run.sh
#
# Build output goes to a temporary folder, which is removed afterwards.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(dirname "$here")"
cli="$root/silica"
work="$(mktemp -d "${TMPDIR:-/tmp}/silica-cli-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT

passed=0
failed=0
pass() { passed=$((passed + 1)); printf 'ok   %s\n' "$1"; }
fail() { failed=$((failed + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     /'; }

# expect <name> <expected-exit> <expected-stdout-or-empty> -- <command...>
expect() {
  local name="$1" want_ec="$2" want_out="$3"; shift 4
  local out ec
  out="$("$@" 2>"$work/stderr")"; ec=$?
  if [ "$ec" != "$want_ec" ]; then
    fail "$name" "exit $ec, wanted $want_ec; stderr:
$(cat "$work/stderr")"
  elif [ -n "$want_out" ] && [ "$out" != "$want_out" ]; then
    fail "$name" "stdout: $out
wanted: $want_out"
  else
    pass "$name"
  fi
}

# --- fixtures -------------------------------------------------------------

mkdir -p "$work/hello-world"
cat > "$work/hello-world/main.silica" <<'EOF'
fn main() -> atom {
    sequence proc[device_io]
        _: atom <- println("Hello, world!")
    produces
        pure :ok
    end
}
EOF

mkdir -p "$work/single"
cat > "$work/single/greet.silica" <<'EOF'
fn main() -> atom {
    sequence proc[device_io]
        _: atom <- println("greetings")
    produces
        pure :ok
    end
}
EOF

mkdir -p "$work/broken"
cat > "$work/broken/main.silica" <<'EOF'
fn main() -> atom {
    this is not silica
}
EOF

# A program on the standard library's FFI wrappers: its sidecar and C archive come from the
# library, not the project. The (:tcp) carrier binds a free loopback port and the program ends.
mkdir -p "$work/ffi-stdlib"
cat > "$work/ffi-stdlib/dangerous_listen.silica" <<'EOF'
module dangerous_listen;

use dangerous_tcp_carrier;

fn region_dump_limit() -> int64 {
    0
}

fn reporter(_report: string, state: { seen: int64 }) -> (:no_reply, { seen: int64 }) {
    (:no_reply, { seen: state.seen + 1 })
}

fn owner(msg: (:link_up, string) | (:accepted, dangerous_actor_ref, string) | (:rx, string) | (:tx_credit, int64) | (:tx_failed, atom) | (:link_down, atom),
         state: { up: int64 }) -> (:no_reply, { up: int64 }) {
    case msg of {
        (:link_up, _info: string) -> {
            sequence proc[concurrency, device_io]
                _: atom <- println("listening");
                _: boolean <- cast_exit(0)
            produces
                pure (:no_reply, { up: state.up + 1 })
            end
        };
        (:accepted, _conn: dangerous_actor_ref, _peer: string) -> (:no_reply, state);
        (:rx, _bytes: string) -> (:no_reply, state);
        (:tx_credit, _n: int64) -> (:no_reply, state);
        (:tx_failed, _why: atom) -> (:no_reply, state);
        (:link_down, _why2: atom) -> (:no_reply, state)
    }
}

fn main() -> int64 {
    sequence proc[concurrency, device_io]
        rep: actor_ref <- spawn({ seen: 0 }, reporter, stack_policy(0, :keep_last_message), state_policy(:keep_state_area));
        _: atom <- register_failure_reporter(rep);
        car: dangerous_actor_ref <- spawn_dangerous({ owner: actor_ref_of_word(0), fd: 0 - 1, rx_credit: 0, up: false, listening: false, link_spec: "" }, dangerous_tcp_carrier@carrier, stack_policy(0, :keep_last_message), state_policy(:keep_state_area));
        own: actor_ref <- spawn({ up: 0 }, owner, stack_policy(0, :keep_last_message), state_policy(:keep_state_area));
        _: boolean <- cast(car, (:open, own, "listen:0") impl ActorMessage {});
        code: int64 <- wait_for_exit()
    produces
        pure code
    end
}
EOF

echo "not a program" > "$work/notes.txt"

mkdir -p "$work/no-entry"
printf 'fn helper() -> atom {\n    :ok\n}\n' > "$work/no-entry/helper.silica"

# --- tests ----------------------------------------------------------------

expect "version"                        0 "" -- "$cli" version
expect "help"                           0 "" -- "$cli" help
expect "unknown command fails"          1 "" -- "$cli" frobnicate
expect "run without a path fails"       1 "" -- "$cli" run
expect "missing path fails"             1 "" -- "$cli" build "$work/does-not-exist"
expect "non-.silica file fails"         1 "" -- "$cli" build "$work/notes.txt"

# A Silica main returning :ok exits with :ok's atom index, 2.
expect "run example folder"             2 "Hello, world!" -- "$cli" run "$work/hello-world"
expect "run single file"                2 "greetings"     -- "$cli" run "$work/single/greet.silica"
expect "build with -o"                  0 ""              -- "$cli" build "$work/single/greet.silica" -o "$work/out/greet"
expect "built executable runs"          2 "greetings"     -- "$work/out/greet"
expect "compile error fails"            1 ""              -- "$cli" build "$work/broken"
expect "folder without entry fails"     1 ""              -- "$cli" build "$work/no-entry"
# The standard library is downloaded on demand when SILICA_STDLIB is not set.
expect "run stdlib FFI program"         0 "listening"     -- "$cli" run "$work/ffi-stdlib"
if [ -n "$(find "$work/ffi-stdlib" -not -path '*/.silica-build*' -name '*.a')" ]; then
  fail "FFI archive stays in the build folder" "$(find "$work/ffi-stdlib" -not -path '*/.silica-build*' -name '*.a')"
else
  pass "FFI archive stays in the build folder"
fi

# --host and --target. This machine's own target, by any spelling, is the default build.
machine="$("$cli" version | sed -n 's/^platform: //p')"
expect "run --target this machine"      2 "greetings"     -- "$cli" run "$work/single/greet.silica" --target "$machine"
expect "run --target= --host="          2 "greetings"     -- "$cli" run "$work/single/greet.silica" --target="$machine" --host="$machine"
expect "unknown host fails"             1 ""              -- "$cli" build "$work/single/greet.silica" --host windows
expect "invalid target fails"           1 ""              -- "$cli" build "$work/single/greet.silica" --target 'a/b'
expect "--target without a value fails" 1 ""              -- "$cli" build "$work/single/greet.silica" --target
expect "run on a board target fails"    1 ""              -- "$cli" run "$work/single/greet.silica" --target ESP32_S3_raw
# Releases carry an ESP32-S3 cross compiler for macOS only. Building for it downloads it.
home="${SILICA_HOME:-$HOME/.silica}"
if [ "$machine" = macos-applesilicon ]; then
  expect "build for a board target"     0 ""              -- "$cli" build "$work/single/greet.silica" --target esp32-s3_raw
  if [ -f "$work/single/.silica-build/ESP32_S3_raw/greet/greet.sams" ] && [ -x "$home/bin/silica-compiler-ESP32_S3_raw" ]; then
    pass "board build installs its compiler and emits assembly"
  else
    fail "board build installs its compiler and emits assembly"
  fi
  expect "-o with a board target fails" 1 ""              -- "$cli" build "$work/single/greet.silica" --target ESP32_S3_raw -o "$work/x"
  # A near-miss target name fails with the command it should have been.
  expect "near-miss target fails"       1 ""              -- "$cli" build "$work/single/greet.silica" --target esp32-s3
  if grep -F "silica build $work/single/greet.silica --target ESP32_S3_raw" "$work/stderr" >/dev/null; then
    pass "near-miss target suggests the right command"
  else
    fail "near-miss target suggests the right command" "$(cat "$work/stderr")"
  fi
fi

# `silica update` also refreshes every cross compiler that is installed.
if [ -f "$home/bin/silica-compiler-ESP32_S3_raw.release" ]; then
  echo "compiler-old silica-999999-ESP32_S3_raw-$machine" > "$home/bin/silica-compiler-ESP32_S3_raw.release"
  expect "update refreshes cross compilers" 0 ""          -- "$cli" update
  if grep -q '^compiler-old ' "$home/bin/silica-compiler-ESP32_S3_raw.release"; then
    fail "cross compiler updated" "$(cat "$home/bin/silica-compiler-ESP32_S3_raw.release")"
  else
    pass "cross compiler updated"
  fi
fi
expect "update bad option fails"        1 ""              -- "$cli" update --bogus

# `silica update` installs the specification flat into $SILICA_HOME/spec.
spec_dir="${SILICA_HOME:-$HOME/.silica}/spec"
expect "update"                         0 ""              -- "$cli" update
if [ ! -f "$spec_dir/silica-specification.md" ]; then
  fail "specification installed" "no $spec_dir/silica-specification.md"
elif [ -n "$(find "$spec_dir" -mindepth 1 \( -type d -o \! -name '*.md' \))" ]; then
  fail "specification is flat Markdown" "$(find "$spec_dir" -mindepth 1 \( -type d -o \! -name '*.md' \))"
else
  pass "specification is flat Markdown"
fi

expect "spec --path"                    0 "$spec_dir"     -- "$cli" spec --path
expect "spec guide"                     0 ""              -- "$cli" spec
# Capture first: grep -q would close the pipe early and pipefail would report that.
spec_out="$("$cli" spec 2>&1)"
if printf '%s\n' "$spec_out" | grep -F "$spec_dir/silica-specification.md" >/dev/null; then
  pass "spec guide names the specification"
else
  fail "spec guide names the specification"
fi
expect "spec when not installed fails"  1 ""              -- env SILICA_HOME="$work/empty-home" "$cli" spec
expect "spec bad option fails"          1 ""              -- "$cli" spec --bogus

if [ -n "$(find "$work/single" -name '*.sams' -not -path '*/.silica-build/*')" ]; then
  fail "source tree stays clean" "compiler output found outside .silica-build"
else
  pass "source tree stays clean"
fi

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
