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

# Pack a text file into a store backing. Checked here, without a compiler: the
# on-medium form is the one storelog.silica reads (4096-byte blocks, CRC-32C).
printf 'alpha\n\nbeta \r\n  \n' > "$work/lines.txt"
expect "sildat packs lines" 0 "wrote 2 lines in 1 block to $work/lines.sildat (capacity 4096)" \
  -- "$cli" sildat "$work/lines.txt" "$work/lines.sildat"
python3 - "$work/lines.sildat" <<'PY'
import struct, sys
path = sys.argv[1]
data = open(path, "rb").read()
assert len(data) == 4096, len(data)

def crc32c(buf):
    c = 0xFFFFFFFF
    for b in buf:
        c ^= b
        for _ in range(8):
            c = (c >> 1) ^ 0x82F63B78 if c & 1 else c >> 1
    return c ^ 0xFFFFFFFF

body = data[:12]
assert struct.unpack(">QI", body) == (0, 1), struct.unpack(">QI", body)
assert struct.unpack(">I", data[12:16])[0] == crc32c(body)
# record 0: length, seq 0, crc, then one :storage frame of the ETF string "alpha"
length, seq = struct.unpack(">IQ", data[16:28])
payload = data[32:32 + length]
assert seq == 0 and crc32c(data[16:28] + payload) == struct.unpack(">I", data[28:32])[0]
assert payload[:4] == b"\x00\x00\x80\x00"          # frame_seq 0, index 0 | last
assert payload[4:7] == b"\x01\x00\x01"              # :etf, schema 1
assert payload[7:9] == bytes([131, 109])            # ETF BINARY_EXT
assert struct.unpack(">I", payload[9:13])[0] == 5 and payload[13:18] == b"alpha"
# The next record is "beta " with its trailing space kept, and the blank lines gone.
nxt = 32 + length
nlen, nseq = struct.unpack(">IQ", data[nxt:nxt + 12])
npayload = data[nxt + 16:nxt + 16 + nlen]
assert nseq == 1 and crc32c(data[nxt:nxt + 12] + npayload) == struct.unpack(">I", data[nxt + 12:nxt + 16])[0]
assert npayload[13:] == b"beta "
assert data[nxt + 16 + nlen:].strip(b"\x00") == b""
PY
if [ $? -eq 0 ]; then pass "sildat backing layout"; else fail "sildat backing layout" "header, crc or payload mismatch"; fi

expect "sildat needs two paths" 1 "" -- "$cli" sildat "$work/lines.txt"
"$cli" sildat --capacity 1000 "$work/lines.txt" "$work/bad.sildat" >/dev/null 2>"$work/stderr"
if [ $? -eq 1 ] && grep -q "multiple of 4096" "$work/stderr"; then pass "sildat rejects a bad capacity"; else fail "sildat rejects a bad capacity" "$(cat "$work/stderr")"; fi
# Each short record is 34 bytes. 200 of them need a second block.
python3 -c 'open("'"$work"'/many.txt","wb").write(b"x\n"*200)'
"$cli" sildat --capacity 4096 "$work/many.txt" "$work/many.sildat" >/dev/null 2>"$work/stderr"
if [ $? -eq 1 ] && grep -q "does not fit" "$work/stderr"; then pass "sildat rejects an undersized capacity"; else fail "sildat rejects an undersized capacity" "$(cat "$work/stderr")"; fi
python3 -c 'open("'"$work"'/long.txt","wb").write(b"a"*4052 + b"\n")'
"$cli" sildat "$work/long.txt" "$work/long.sildat" >/dev/null 2>"$work/stderr"
if [ $? -eq 1 ] && grep -q "at most 4051" "$work/stderr"; then pass "sildat rejects a long line"; else fail "sildat rejects a long line" "$(cat "$work/stderr")"; fi
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

# An unchanged project reuses its last program; any change, or --rebuild, compiles again.
# expect_step <name> <step word> <wanted 0|1>: whether the last command's stderr showed that step.
expect_step() {
  if grep -qE "^ *$2 " "$work/stderr"; then got=1; else got=0; fi
  if [ "$got" = "$3" ]; then pass "$1"; else fail "$1" "$(cat "$work/stderr")"; fi
}
expect "rerun unchanged folder"         2 "Hello, world!" -- "$cli" run "$work/hello-world"
expect_step "unchanged folder is not recompiled" Compiling 0
expect_step "unchanged folder reports Fresh"     Fresh     1
expect "rerun stdlib FFI program"       0 "listening"     -- "$cli" run "$work/ffi-stdlib"
expect_step "unchanged FFI program is not recompiled" Compiling 0
expect "rerun with --rebuild"           2 "Hello, world!" -- "$cli" run "$work/hello-world" --rebuild
expect_step "--rebuild recompiles"               Compiling 1
cp "$work/hello-world/main.silica" "$work/hello-main.orig"
sed 's/Hello, world!/Hello, again!/' "$work/hello-main.orig" > "$work/hello-world/main.silica"
expect "run after an edit"              2 "Hello, again!" -- "$cli" run "$work/hello-world"
expect_step "edited folder is recompiled"        Compiling 1
# Assembly that comes out the same keeps its object; a kept FFI archive is not built again.
printf '// a comment\n' >> "$work/hello-world/main.silica"
expect "run after a comment-only edit"  2 "Hello, again!" -- "$cli" run "$work/hello-world"
if grep -qE "Assembling hello-world \(0 of [0-9]+ changed\)" "$work/stderr"; then
  pass "unchanged assembly is not assembled again"
else
  fail "unchanged assembly is not assembled again" "$(cat "$work/stderr")"
fi
printf '// a comment\n' >> "$work/ffi-stdlib/main.silica"
expect "run FFI program after an edit"  0 "listening"     -- "$cli" run "$work/ffi-stdlib"
expect_step "kept FFI archive is not rebuilt"    Building  0
cp "$work/broken/"*.silica "$work/hello-world/main.silica"
expect "edit that breaks the build"     1 ""              -- "$cli" run "$work/hello-world"
cp "$work/hello-main.orig" "$work/hello-world/main.silica"
expect "run after a failed build"       2 "Hello, world!" -- "$cli" run "$work/hello-world"
expect_step "failed build is not reused"         Compiling 1
rm "$work/hello-world/.silica-build/hello-world/hello-world"
expect "run after the program is deleted" 2 "Hello, world!" -- "$cli" run "$work/hello-world"
expect_step "deleted program is rebuilt"         Compiling 1

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

# --- update --golden (gh is stubbed; no network) --------------------------

gold="$work/golden"
mkdir -p "$gold/bin" "$gold/fixture/golden-linux_x86_64-shard-0" "$gold/fixture/golden-ESP32-S3_raw-shard-0" \
         "$gold/silica/trials/foo_addition" "$gold/silica/trials/other"
cat > "$gold/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  auth) exit 0 ;;
  api) printf 'golden-linux_x86_64-shard-0\ngolden-ESP32-S3_raw-shard-0\nlogs-other\n'; exit 0 ;;
  run)
    if [ "$2" = list ]; then echo 4242; exit 0; fi
    # run download <id> -R <repo> -n <name> -D <dir>
    name=""; dir=""
    while [ $# -gt 0 ]; do case "$1" in -n) name="$2"; shift ;; -D) dir="$2"; shift ;; esac; shift; done
    cp -R "$GOLDEN_FIXTURE/$name/." "$dir/"; exit 0 ;;
esac
exit 1
EOF
chmod +x "$gold/bin/gh"
fx="$gold/fixture/golden-linux_x86_64-shard-0"
mkdir -p "$fx/foo_addition" "$fx/newsuite"
printf 'new asm\n' > "$fx/foo_addition/bar.ascomp"
printf 'same\n' > "$fx/foo_addition/same.scout"
printf 'evil\n' > "$fx/foo_addition/bad.txt"
printf 'nosuite\n' > "$fx/newsuite/x.ascomp"
printf 'target=linux_x86_64\nfoo_addition/bar.ascomp\nfoo_addition/same.scout\n../escape.ascomp\n/abs/x.ascomp\nfoo_addition/../../escape2.ascomp\nfoo_addition/bad.txt\nnewsuite/x.ascomp\nMANIFEST.txt\n' > "$fx/MANIFEST.txt"
fe="$gold/fixture/golden-ESP32-S3_raw-shard-0"
mkdir -p "$fe/other"; printf 'esp asm\n' > "$fe/other/q.ESP32-S3_raw.ascomp"
printf 'target=ESP32-S3_raw\nother/q.ESP32-S3_raw.ascomp\n' > "$fe/MANIFEST.txt"
st="$gold/silica/trials"
printf 'old asm\n' > "$st/foo_addition/bar.ascomp"
printf 'same\n' > "$st/foo_addition/same.scout"
ggh() { env PATH="$gold/bin:$PATH" GOLDEN_FIXTURE="$gold/fixture" "$cli" update --golden --silica-dir "$gold/silica" "$@"; }

expect "golden dry-run succeeds"        0 ""              -- ggh --dry-run
if [ "$(cat "$st/foo_addition/bar.ascomp")" = "old asm" ] && [ ! -e "$st/other/q.ESP32-S3_raw.ascomp" ]; then
  pass "golden dry-run changes nothing"
else fail "golden dry-run changes nothing"; fi

printf 'secret\n' > "$gold/secret.txt"
ln -s "$gold/secret.txt" "$fx/foo_addition/link.ascomp"
printf 'foo_addition/link.ascomp\n' >> "$fx/MANIFEST.txt"
expect "golden install"                 0 ""              -- ggh --run 4242
[ "$(cat "$st/foo_addition/bar.ascomp")" = "new asm" ] && pass "golden overwrites existing file" || fail "golden overwrites existing file"
[ -f "$st/other/q.ESP32-S3_raw.ascomp" ] && pass "golden installs new file" || fail "golden installs new file"
[ ! -e "$st/MANIFEST.txt" ] && [ ! -e "$st/foo_addition/MANIFEST.txt" ] && pass "golden does not copy MANIFEST.txt" || fail "golden does not copy MANIFEST.txt"
if [ ! -e "$gold/silica/escape.ascomp" ] && [ ! -e "$gold/escape2.ascomp" ] && [ ! -e "$st/foo_addition/bad.txt" ] \
   && [ ! -d "$st/newsuite" ]; then
  pass "golden rejects traversal, absolute, bad extension, new suites"
else fail "golden rejects traversal, absolute, bad extension, new suites"; fi
out="$(ggh --run https://github.com/Silica-Language-and-Compiler/silica/actions/runs/4242 2>&1)"
case "$out" in *"1 unchanged"*"skipped"*) pass "golden summary reports unchanged/skipped" ;; *) fail "golden summary reports unchanged/skipped" "$out" ;; esac
[ ! -e "$st/foo_addition/link.ascomp" ] && pass "golden rejects symlinked artifact files" || fail "golden rejects symlinked artifact files"
printf 'old asm\n' > "$st/foo_addition/bar.ascomp"
expect "golden --target filter"         0 ""              -- ggh --target ESP32-S3_raw
[ "$(cat "$st/foo_addition/bar.ascomp")" = "old asm" ] && pass "golden --target skips other targets" || fail "golden --target skips other targets"
expect "golden no matching artifacts fails" 1 ""          -- ggh --target nonesuch
expect "golden bad --run fails"         1 ""              -- ggh --run abc

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
