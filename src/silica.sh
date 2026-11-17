#!/usr/bin/env bash
# silica — command line front end for the Silica compiler.
#
#   silica build <file-or-folder>   compile, assemble and link an executable
#   silica run   <file-or-folder>   build, then execute it
#   silica update                   update every installed compiler, the specification and stdlib
#   silica spec [--path]            where the specification is and how to read it (for AI)
#   silica version                  show which compiler is in use
#
# The compiler binary lives in ~/.silica/bin (override with SILICA_HOME). When it is
# missing, the newest GitHub release is queried and the binary for this machine is
# downloaded, along with the release's specification, unpacked flat into ~/.silica/spec.
# SILICA_COMPILER=/path/to/silica-compiler skips the download entirely.
#
# Written for the bash 3.2 that ships with macOS: no associative arrays, no mapfile.
set -uo pipefail

# Replaced with the release tag by the release workflow.
SILICA_CLI_VERSION="dev"

SILICA_REPO="${SILICA_REPO:-Silica-Language-and-Compiler/silica}"
SILICA_HOME="${SILICA_HOME:-$HOME/.silica}"
SILICA_BIN_DIR="$SILICA_HOME/bin"
SILICA_INSTALLED_COMPILER="$SILICA_BIN_DIR/silica-compiler"
SILICA_VERSION_FILE="$SILICA_BIN_DIR/silica-compiler.release"
SILICA_SPEC_DIR="$SILICA_HOME/spec"
SILICA_SPEC_VERSION_FILE="$SILICA_HOME/spec.release"  # outside spec/, which holds only .md
SILICA_STDLIB_DIR="$SILICA_HOME/stdlib"
SILICA_STDLIB_VERSION_FILE="$SILICA_HOME/stdlib.release"
BUILD_DIR_NAME=".silica-build"
# Library modules: SILICA_STDLIB, else ~/.silica/stdlib when it exists (a build that needs it
# downloads it first; see ensure_stdlib).
if [ -z "${SILICA_STDLIB:-}" ] && [ -d "$SILICA_STDLIB_DIR" ]; then SILICA_STDLIB="$SILICA_STDLIB_DIR"; fi

# ---------------------------------------------------------------------------
# output helpers

if [ -t 2 ]; then
  c_red=$'\033[31m'; c_green=$'\033[32m'; c_cyan=$'\033[36m'; c_dim=$'\033[2m'; c_bold=$'\033[1m'; c_off=$'\033[0m'
else
  c_red=; c_green=; c_cyan=; c_dim=; c_bold=; c_off=
fi

die()  { printf '%serror:%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }
info() { printf '%s%s%s\n' "$c_dim" "$*" "$c_off" >&2; }
warn() { printf '%swarning:%s %s\n' "$c_red" "$c_off" "$*" >&2; }
step() { printf '%s%12s%s %s\n' "$c_green$c_bold" "$1" "$c_off" "$2" >&2; }

usage() {
  cat <<'EOF'
Usage: silica <command> [options] <file-or-folder>

Commands:
  build <path>    Compile <path> (a .silica file or a project folder) to an executable
  run <path>      Build <path>, then execute it (extra args after -- go to the program)
  update          Bring every compiler in ~/.silica/bin (this machine's and any cross
                  compilers) up to the latest release, and install the language
                  specification (Markdown) into ~/.silica/spec and the standard
                  library sources into ~/.silica/stdlib. --target/--host also
                  install that compiler.
  spec            Explain where the language specification is and how to use it
                  (written for AI agents; --path prints just the folder)
  version         Print the compiler in use and the release it came from
  help            Show this message

Options for build and run:
  -o, --output <file>   Where to write the executable
                        (default: <project>/.silica-build/<name>/<name>)
  -v, --verbose         Show the compiler's full output
  --target <target>     Generate code for <target>: a platform (macos-applesilicon,
                        linux-aarch64, linux-x86_64) or a board (ESP32_S3_raw).
                        Default: this machine. A missing compiler is downloaded.
  --host <platform>     Use a compiler that runs on <platform> (default: this machine)

Environment:
  SILICA_COMPILER   Use this compiler binary instead of ~/.silica/bin/silica-compiler
  SILICA_HOME       Install root (default: ~/.silica)
  SILICA_STDLIB     A folder of library .silica modules; a `use X;` that is not part of
                    the project is resolved to $SILICA_STDLIB/**/X.silica
                    (default: ~/.silica/stdlib, downloaded when first needed)
  GITHUB_TOKEN      Optional; raises the GitHub API rate limit when downloading

Examples:
  silica build hello.silica
  silica run my_app/
  silica run my_app -- --some-arg
  silica build my_app --target linux-aarch64
  silica build my_app --target ESP32_S3_raw
EOF
}

# ---------------------------------------------------------------------------
# platforms (mirrors project_makefiles/platform/platforms.mk)
#
# Two axes, as in the compiler repository:
#   host platform   where a compiler binary RUNS   (macos-applesilicon, linux-aarch64, linux-x86_64)
#   emit target     what a compiler generates code FOR: a host platform, or a board (ESP32_S3_raw)
#
# Release assets: silica-NNNNNN-<host> emits code for <host> itself; a cross compiler is
# silica-NNNNNN-<token>-<host>, where <token> is the emit target with hyphens turned into
# underscores (linux_aarch64, ESP32_S3_raw).

HOST_PLATFORMS="macos-applesilicon linux-aarch64 linux-x86_64"
# Board targets, spelled as their release assets spell them. Others are accepted as given.
KNOWN_BOARDS="ESP32_S3_raw STM32_L476RG_raw"

# The platform this machine is. (Named host_platform for history: it is the default --host.)
host_platform() {
  local s m
  s="$(uname -s)"; m="$(uname -m)"
  case "$s:$m" in
    Darwin:arm64)                     echo macos-applesilicon ;;
    Linux:aarch64|Linux:arm64)        echo linux-aarch64 ;;
    Linux:x86_64)                     echo linux-x86_64 ;;
    *) die "no Silica compiler is published for $s $m (supported: macOS Apple Silicon, Linux aarch64, Linux x86-64)" ;;
  esac
}

lowercase() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Platform id for a host or target name in any of its spellings, or nothing for a board.
platform_of() { # platform_of <name>
  case "$(lowercase "$1")" in
    macos-applesilicon|macos_applesilicon|apple_silicon_mac|apple-silicon-mac) echo macos-applesilicon ;;
    linux-aarch64|linux_aarch64|linux-arm64|linux_arm64) echo linux-aarch64 ;;
    linux-x86_64|linux_x86_64|linux-x86-64|linux-amd64|linux_amd64) echo linux-x86_64 ;;
  esac
}

# The cross-compiler token for an emit target: the repository's emit-target name for a host
# platform (linux-aarch64 -> linux_aarch64), the name with underscores for a board.
target_token() { # target_token <platform-or-board>
  case "$1" in
    macos-applesilicon) echo apple_silicon_mac ;;
    linux-aarch64)      echo linux_aarch64 ;;
    linux-x86_64)       echo linux_x86_64 ;;
    *)                  printf '%s\n' "$1" | tr - _ ;;
  esac
}

# Validates --host / --target and sets, for the compiler that build, run and update work with:
#   SEL_HOST              the platform the compiler runs on
#   SEL_TARGET            what it emits code for: a host platform id, or a board name
#   SEL_TARGET_PLATFORM   the platform that runs the program (empty for a board)
#   SEL_TOKEN             the asset token (empty when the compiler is native: target = host)
#   SEL_LINK              its link in ~/.silica/bin, with the release record at "$SEL_LINK.release"
select_compiler() { # select_compiler <host-or-empty> <target-or-empty>
  local machine host target
  machine="$(host_platform)"
  if [ -n "$1" ]; then
    host="$(platform_of "$1")"
    [ -n "$host" ] || die "unknown host platform: $1 (expected one of: $HOST_PLATFORMS)"
  else
    host="$machine"
  fi
  target="${2:-$machine}"
  case "$target" in *[!A-Za-z0-9_-]*|'') die "invalid target name: $target" ;; esac

  SEL_HOST="$host"
  SEL_TARGET_PLATFORM="$(platform_of "$target")"
  if [ -n "$SEL_TARGET_PLATFORM" ]; then
    SEL_TARGET="$SEL_TARGET_PLATFORM"
  else
    # A board, named by its asset token: ESP32-S3_raw and esp32_s3_raw are both ESP32_S3_raw.
    local board
    SEL_TARGET="$(target_token "$target")"
    for board in $KNOWN_BOARDS; do
      if [ "$(lowercase "$board")" = "$(lowercase "$SEL_TARGET")" ]; then SEL_TARGET="$board"; fi
    done
  fi
  if [ "$SEL_TARGET_PLATFORM" = "$host" ]; then SEL_TOKEN=""; else SEL_TOKEN="$(target_token "$SEL_TARGET")"; fi

  # silica-compiler is this machine's native compiler (as it always was); a cross compiler is
  # silica-compiler-<token>, and one for another host also names that host.
  if [ "$host" = "$machine" ]; then
    if [ -z "$SEL_TOKEN" ]; then SEL_LINK="$SILICA_INSTALLED_COMPILER"
    else SEL_LINK="$SILICA_INSTALLED_COMPILER-$SEL_TOKEN"; fi
  else
    SEL_LINK="$SILICA_INSTALLED_COMPILER-$(target_token "$SEL_TARGET")@$host"
  fi
  # A board's spelling may differ in case from the installed link; reuse the installed one.
  if [ -n "$SEL_TOKEN" ] && [ ! -e "$SEL_LINK" ] && [ -d "$SILICA_BIN_DIR" ]; then
    local f want; want="$(lowercase "${SEL_LINK##*/}")"
    for f in "$SILICA_BIN_DIR"/silica-compiler-*; do
      case "$f" in *.release) continue ;; esac
      if [ "$(lowercase "${f##*/}")" = "$want" ]; then SEL_LINK="$f"; break; fi
    done
  fi

  if [ "$host" != "$machine" ]; then
    warn "using a compiler built for $host on this $machine machine; it may not run here"
  fi
}

# "linux-aarch64", or "ESP32_S3_raw (cross compiler on macos-applesilicon)", for messages.
describe_selection() {
  if [ -z "$SEL_TOKEN" ]; then printf '%s\n' "$SEL_TARGET"
  else printf '%s (cross compiler on %s)\n' "$SEL_TARGET" "$SEL_HOST"; fi
}

# ---------------------------------------------------------------------------
# compiler download

http_get() { # http_get <url> → stdout
  local auth=()
  if [ -n "${GITHUB_TOKEN:-}" ]; then auth=(-H "Authorization: Bearer $GITHUB_TOKEN"); fi
  curl -fsSL -H "Accept: application/vnd.github+json" ${auth[@]+"${auth[@]}"} "$1"
}

# Queries the latest release once (later calls reuse it) and sets:
#   REL_TAG        the release tag
#   REL_URLS       every asset's download URL, one per line
#   REL_SPEC_URL   silica-specification.zip (empty when the release has none)
query_latest_release() {
  [ -z "${REL_TAG:-}" ] || return 0
  local json url
  command -v curl >/dev/null 2>&1 || die "curl is required to download the compiler"
  json="$(http_get "https://api.github.com/repos/$SILICA_REPO/releases/latest")" \
    || die "could not query https://github.com/$SILICA_REPO/releases/latest"

  REL_TAG="$(printf '%s\n' "$json" | sed -n 's/^ *"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)"
  [ -n "$REL_TAG" ] || die "the latest release of $SILICA_REPO has no tag name"
  REL_URLS="$(printf '%s\n' "$json" | sed -n 's/^ *"browser_download_url": *"\([^"]*\)".*/\1/p')"
  REL_SPEC_URL=
  while IFS= read -r url; do
    [ "${url##*/}" = silica-specification.zip ] && REL_SPEC_URL="$url"
  done <<< "$REL_URLS"
}

# Splits a compiler asset name into its parts, or returns 1 when it is not one:
#   silica-NNNNNN-<host>           ASSET_NUM ASSET_HOST, ASSET_TOKEN empty
#   silica-NNNNNN-<token>-<host>   ASSET_NUM ASSET_TOKEN ASSET_HOST
# The compiler repository's seed compilers (token "seed") are not for users and are skipped.
parse_compiler_asset() { # parse_compiler_asset <name>
  local name="$1" rest h
  case "$name" in silica-[0-9]*) ;; *) return 1 ;; esac
  rest="${name#silica-}"; ASSET_NUM="${rest%%-*}"; rest="${rest#*-}"
  case "$ASSET_NUM" in ''|*[!0-9]*) return 1 ;; esac
  for h in $HOST_PLATFORMS; do
    if [ "$rest" = "$h" ]; then ASSET_HOST="$h"; ASSET_TOKEN=""; return 0; fi
    case "$rest" in
      *-"$h") ASSET_HOST="$h"; ASSET_TOKEN="${rest%-"$h"}"
              case "$ASSET_TOKEN" in ''|seed|*-*) return 1 ;; esac
              return 0 ;;
    esac
  done
  return 1
}

# Finds the compiler for <host> emitting <token> (empty: native) in the latest release and sets
# REL_COMPILER_NAME/_URL. Tokens compare case-insensitively. The numbers count down, so the
# lowest number is the newest compiler. Returns 1 when the release has none.
find_release_compiler() { # find_release_compiler <host> <token>
  local host="$1" token best_num="" url
  token="$(lowercase "$2")"
  query_latest_release
  REL_COMPILER_NAME=; REL_COMPILER_URL=
  while IFS= read -r url; do
    parse_compiler_asset "${url##*/}" || continue
    [ "$ASSET_HOST" = "$host" ] && [ "$(lowercase "$ASSET_TOKEN")" = "$token" ] || continue
    if [ -z "$best_num" ] || [ "$ASSET_NUM" -lt "$best_num" ]; then
      best_num="$ASSET_NUM"; REL_COMPILER_NAME="${url##*/}"; REL_COMPILER_URL="$url"
    fi
  done <<< "$REL_URLS"
  [ -n "$REL_COMPILER_URL" ]
}

# The targets the latest release has compilers for on <host>, space-separated.
release_targets_for_host() { # release_targets_for_host <host>
  local url out="" p
  query_latest_release
  while IFS= read -r url; do
    parse_compiler_asset "${url##*/}" || continue
    [ "$ASSET_HOST" = "$1" ] || continue
    if [ -z "$ASSET_TOKEN" ]; then out="$out $1"
    else p="$(platform_of "$ASSET_TOKEN")"; out="$out ${p:-$ASSET_TOKEN}"; fi
  done <<< "$REL_URLS"
  printf '%s\n' $out | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//'
}

# Downloads REL_COMPILER_NAME into ~/.silica/bin and points <link> at it, recording the release
# in <link>.release. Does nothing when <link> already is that compiler.
install_compiler_from_release() { # install_compiler_from_release <link>
  local link="$1" tag="$REL_TAG" name="$REL_COMPILER_NAME" url="$REL_COMPILER_URL" tmp

  if [ -x "$link" ] && [ -f "$link.release" ] && [ "$(cat "$link.release")" = "$tag $name" ]; then
    info "compiler is already the latest ($name from $tag)"
    return 0
  fi

  step Downloading "$name ($tag)"
  mkdir -p "$SILICA_BIN_DIR" || die "cannot create $SILICA_BIN_DIR"
  tmp="$SILICA_BIN_DIR/.$name.part"
  rm -f "$tmp"
  if ! curl -fL --progress-bar -o "$tmp" "$url"; then
    rm -f "$tmp"
    die "download failed: $url"
  fi
  chmod +x "$tmp"
  mv -f "$tmp" "$SILICA_BIN_DIR/$name"
  ln -sfn "$name" "$link"
  printf '%s %s\n' "$tag" "$name" > "$link.release"
  step Installed "$link -> $name"
}

# Installs the compiler select_compiler chose, from the latest release.
install_selected_compiler() {
  if ! find_release_compiler "$SEL_HOST" "$SEL_TOKEN"; then
    local have guess msg
    have="$(release_targets_for_host "$SEL_HOST")"
    msg="release $REL_TAG has no compiler for target $SEL_TARGET on $SEL_HOST"
    [ -z "$have" ] || msg="$msg

Targets available on $SEL_HOST: $have"
    guess="$(closest_target "$SEL_TARGET" "$have")"
    [ -z "$guess" ] || msg="$msg

Did you mean:
    $(command_with_target "$guess")"
    die "$msg"
  fi
  install_compiler_from_release "$SEL_LINK"
}

# The candidate closest to <name>, or nothing when none is close. Names compare in lowercase with
# only letters and digits kept, so esp32-s3, ESP32_S3 and esp32s3raw are all alike. A candidate
# that contains the name (or is contained by it) wins; otherwise the smallest edit distance, up
# to a third of the name's length.
closest_target() { # closest_target <name> <space-separated candidates>
  printf '%s\n' $2 | awk -v want="$1" '
    function norm(s) { s = tolower(s); gsub(/[^a-z0-9]/, "", s); return s }
    function dist(a, b,   i, j, la, lb, d, c) {
      la = length(a); lb = length(b)
      for (i = 0; i <= la; i++) d[i, 0] = i
      for (j = 0; j <= lb; j++) d[0, j] = j
      for (i = 1; i <= la; i++) for (j = 1; j <= lb; j++) {
        c = d[i-1, j-1] + (substr(a, i, 1) != substr(b, j, 1))
        if (d[i-1, j] + 1 < c) c = d[i-1, j] + 1
        if (d[i, j-1] + 1 < c) c = d[i, j-1] + 1
        d[i, j] = c
      }
      return d[la, lb]
    }
    BEGIN { w = norm(want); best = ""; bestd = int(length(w) / 3) + 1 }
    $0 != "" {
      c = norm($0)
      if (w != "" && (index(c, w) || index(w, c))) { if (!sub_hit) { sub_hit = $0 }; next }
      d = dist(w, c); if (d < bestd) { bestd = d; best = $0 }
    }
    END { if (sub_hit) print sub_hit; else if (best != "") print best }'
}

# The command line the user ran, with its --target replaced by <target> (or added).
command_with_target() { # command_with_target <target>
  local out="silica" arg skip=0 replaced=0
  for arg in ${SILICA_ARGS[@]+"${SILICA_ARGS[@]}"}; do
    if [ "$skip" = 1 ]; then skip=0; out="$out $1"; continue; fi
    case "$arg" in
      --target)   skip=1; replaced=1; out="$out --target" ;;
      --target=*) replaced=1; out="$out --target=$1" ;;
      *)          out="$out $(printf '%q' "$arg")" ;;
    esac
  done
  [ "$replaced" = 1 ] || out="$out --target $1"
  printf '%s\n' "$out"
}

unzip_to() { # unzip_to <zip> <dir>
  if command -v unzip >/dev/null 2>&1; then
    unzip -q -o "$1" -d "$2"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -I -m zipfile -e "$1" "$2"
  elif command -v bsdtar >/dev/null 2>&1; then
    bsdtar -xf "$1" -C "$2"
  else
    warn "need unzip, python3 or bsdtar to unpack the specification"
    return 1
  fi
}

# Installs the release's silica-specification.zip into ~/.silica/spec as a flat folder of
# Markdown files. The zip keeps repository paths (compiler/design_documents/...), so links
# between the documents are rewritten to bare file names. Returns 1 (with a warning) on failure;
# a missing specification never stops a build.
install_spec_from_release() {
  local tag="$REL_TAG" url="$REL_SPEC_URL" tmp

  if [ -z "$url" ]; then
    warn "release $tag has no silica-specification.zip; specification not installed"
    return 1
  fi
  if [ -d "$SILICA_SPEC_DIR" ] && [ -f "$SILICA_SPEC_VERSION_FILE" ] \
     && [ "$(cat "$SILICA_SPEC_VERSION_FILE")" = "$tag" ]; then
    info "specification is already the latest ($tag)"
    return 0
  fi

  step Downloading "silica-specification.zip ($tag)"
  mkdir -p "$SILICA_HOME" || die "cannot create $SILICA_HOME"
  tmp="$(mktemp -d "$SILICA_HOME/.spec.XXXXXX")" || { warn "cannot create a temporary folder in $SILICA_HOME"; return 1; }

  if ! curl -fsSL -o "$tmp/spec.zip" "$url"; then
    rm -rf "$tmp"; warn "download failed: $url"; return 1
  fi
  mkdir -p "$tmp/unzipped" "$tmp/spec"
  if ! unzip_to "$tmp/spec.zip" "$tmp/unzipped"; then
    rm -rf "$tmp"; warn "could not unpack silica-specification.zip"; return 1
  fi

  # Flatten. The release workflow refuses duplicate file names, but guard anyway.
  local md base count=0
  while IFS= read -r md; do
    base="${md##*/}"
    if [ -e "$tmp/spec/$base" ]; then
      warn "specification has two files named $base; keeping the first"
      continue
    fi
    mv "$md" "$tmp/spec/$base"
    count=$((count + 1))
  done < <(find "$tmp/unzipped" -type f -name '*.md' | LC_ALL=C sort)
  if [ "$count" -eq 0 ]; then
    rm -rf "$tmp"; warn "silica-specification.zip holds no Markdown files"; return 1
  fi

  # ](../../ROADMAP.md) → ](ROADMAP.md), for every file that is part of the flat set.
  local script="$tmp/links.sed" f
  : > "$script"
  for f in "$tmp/spec"/*.md; do
    base="$(basename "$f" | sed 's/[.[\*^$]/\\&/g')"
    printf 's#](\\([^)#]*/\\)\\{0,1\\}%s#](%s#g\n' "$base" "$base" >> "$script"
  done
  for f in "$tmp/spec"/*.md; do
    sed -f "$script" "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  done

  rm -rf "$SILICA_SPEC_DIR"
  mv "$tmp/spec" "$SILICA_SPEC_DIR"
  printf '%s\n' "$tag" > "$SILICA_SPEC_VERSION_FILE"
  rm -rf "$tmp"
  step Installed "$SILICA_SPEC_DIR ($count documents)"
}

# Installs the standard library sources (compiler/stdlib at the release's tag: .silica modules
# plus the .meta sidecars and C sources of their FFI wrappers) into ~/.silica/stdlib. A release
# ships only the compiler binary, so they are fetched from the repository itself: one tree query,
# then the raw files in a single curl run. A folder the CLI did not install (no stdlib.release)
# is the user's own and is left alone. Returns 1 (with a warning) on failure.
install_stdlib_from_release() { # install_stdlib_from_release <tag>
  local tag="$1" tmp json path

  if [ -d "$SILICA_STDLIB_DIR" ] && [ ! -f "$SILICA_STDLIB_VERSION_FILE" ]; then
    info "$SILICA_STDLIB_DIR was not installed by silica; leaving it as it is"
    return 0
  fi
  if [ -d "$SILICA_STDLIB_DIR" ] && [ "$(cat "$SILICA_STDLIB_VERSION_FILE")" = "$tag" ]; then
    info "standard library is already the latest ($tag)"
    return 0
  fi
  command -v curl >/dev/null 2>&1 || { warn "curl is required to download the standard library"; return 1; }

  step Downloading "standard library ($tag)"
  mkdir -p "$SILICA_HOME" || die "cannot create $SILICA_HOME"
  tmp="$(mktemp -d "$SILICA_HOME/.stdlib.XXXXXX")" || { warn "cannot create a temporary folder in $SILICA_HOME"; return 1; }

  if ! json="$(http_get "https://api.github.com/repos/$SILICA_REPO/git/trees/$tag:compiler/stdlib?recursive=1")"; then
    rm -rf "$tmp"; warn "could not list compiler/stdlib at $tag"; return 1
  fi
  # Each tree entry prints "path" before "type"; keep the blobs that are sources.
  : > "$tmp/curl.cfg"
  local count=0
  while IFS= read -r path; do
    case "$path" in *.silica|*.meta|*.c|*.h) ;; *) continue ;; esac
    case "$path" in *'"'*|*'\'*) continue ;; esac
    printf 'url = "https://raw.githubusercontent.com/%s/%s/compiler/stdlib/%s"\noutput = "%s/stdlib/%s"\n' \
      "$SILICA_REPO" "$tag" "$path" "$tmp" "$path" >> "$tmp/curl.cfg"
    count=$((count + 1))
  done < <(printf '%s\n' "$json" | awk '
    /^ *"path": / { p = $0; sub(/^ *"path": *"/, "", p); sub(/",? *$/, "", p) }
    /^ *"type": *"blob"/ { print p }')
  if [ "$count" -eq 0 ]; then
    rm -rf "$tmp"; warn "compiler/stdlib at $tag holds no sources"; return 1
  fi
  if ! curl -fsSL --create-dirs -K "$tmp/curl.cfg"; then
    rm -rf "$tmp"; warn "downloading the standard library failed"; return 1
  fi

  rm -rf "$SILICA_STDLIB_DIR"
  mv "$tmp/stdlib" "$SILICA_STDLIB_DIR"
  printf '%s\n' "$tag" > "$SILICA_STDLIB_VERSION_FILE"
  rm -rf "$tmp"
  step Installed "$SILICA_STDLIB_DIR ($count files)"
}

# `silica update`: brings every compiler installed in ~/.silica/bin up to the latest release (this
# machine's own compiler always, plus each cross compiler a build has installed, plus the one
# --host/--target name), then the specification and standard library. A specification or
# library failure is reported and makes the update fail, but leaves the compilers in place.
install_latest_release() {
  local ec=0 rel link name
  query_latest_release

  find_release_compiler "$(host_platform)" "" || die "release $REL_TAG has no compiler for $(host_platform)"
  install_compiler_from_release "$SILICA_INSTALLED_COMPILER"

  for rel in "$SILICA_BIN_DIR"/silica-compiler-*.release; do
    [ -f "$rel" ] || continue
    link="${rel%.release}"
    name="$(cut -d' ' -f2 "$rel")"
    if ! parse_compiler_asset "$name"; then
      warn "$rel names $name, which is not a compiler release asset; skipping"
      continue
    fi
    if find_release_compiler "$ASSET_HOST" "$ASSET_TOKEN"; then
      install_compiler_from_release "$link"
    else
      warn "release $REL_TAG has no $ASSET_TOKEN compiler for $ASSET_HOST; keeping $name"
    fi
  done

  if [ -n "${SEL_LINK:-}" ] && [ ! -f "$SEL_LINK.release" ]; then install_selected_compiler; fi

  install_spec_from_release || ec=1
  install_stdlib_from_release "$REL_TAG" || ec=1
  return "$ec"
}

# Prints the path of the compiler select_compiler chose, downloading it first if needed. The
# first download of all also installs the specification and standard library.
resolve_compiler() {
  if [ -n "${SILICA_COMPILER:-}" ]; then
    [ -x "$SILICA_COMPILER" ] || die "SILICA_COMPILER is not an executable file: $SILICA_COMPILER"
    printf '%s\n' "$SILICA_COMPILER"
    return
  fi
  if [ ! -x "$SEL_LINK" ]; then
    info "no Silica compiler for $(describe_selection) in $SILICA_BIN_DIR; fetching the latest release"
    {
      install_selected_compiler
      if [ ! -d "$SILICA_SPEC_DIR" ]; then
        install_spec_from_release || true
        install_stdlib_from_release "$REL_TAG" || true
      fi
    } >&2
  fi
  printf '%s\n' "$SEL_LINK"
}

# ---------------------------------------------------------------------------
# project layout

abs_path() { # abs_path <existing path>
  if [ -d "$1" ]; then (cd "$1" && pwd -P)
  else printf '%s/%s\n' "$(cd "$(dirname "$1")" && pwd -P)" "$(basename "$1")"
  fi
}

# Every .silica file under <root>, relative, sorted; build output and VCS dirs skipped.
list_units() {
  (cd "$1" && find . \( -name "$BUILD_DIR_NAME" -o -name .git -o -name _wd_probe -o -name .trial_stdlib \) -prune \
      -o -type f -name '*.silica' -print) | sed 's|^\./||' | LC_ALL=C sort -u
}

# Modules named by `use` lines in the given files (one per line, unique).
used_modules() {
  awk '/^[[:space:]]*use[[:space:]]+/ {
         sub(/^[[:space:]]*use[[:space:]]+/, ""); sub(/;.*$/, "")
         n = split($0, d, /,/)
         for (i = 1; i <= n; i++) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", d[i]); if (d[i] != "") print d[i] }
       }' "$@" | LC_ALL=C sort -u
}

# Topological order of the units listed in <units-file> (paths relative to cwd):
# dependencies first, <entry> last. Same algorithm as project_makefiles/topo_silica_config.sh.
topo_sort() { # topo_sort <units-file> <entry-path>
  awk -v units_file="$1" -v entry="$2" '
  function modname(p, b) { b = p; sub(/^.*\//, "", b); sub(/\.silica$/, "", b); return b }
  function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
  function insert_ready(p, i) { i = ++rn; while (i > 1 && ready[i-1] > p) { ready[i] = ready[i-1]; i-- } ready[i] = p }
  BEGIN {
    n = 0
    while ((getline path < units_file) > 0) {
      if (path == "") continue
      m = modname(path)
      if (m in mod_path && mod_path[m] != path) {
        printf "duplicate module name \"%s\":\n  %s\n  %s\n", m, mod_path[m], path > "/dev/stderr"; exit 1
      }
      mod_path[m] = path; paths[++n] = path; indeg[path] = 0
    }
    close(units_file)
    for (i = 1; i <= n; i++) {
      path = paths[i]
      while ((getline line < path) > 0) {
        if (line !~ /^[[:space:]]*use[[:space:]]+/) continue
        sub(/^[[:space:]]*use[[:space:]]+/, "", line); sub(/;.*$/, "", line)
        nd = split(line, deps, /,/)
        for (d = 1; d <= nd; d++) {
          dep = trim(deps[d])
          if (dep == "" || !(dep in mod_path)) continue
          dp = mod_path[dep]
          if (dp == path || ((dp, path) in seen)) continue
          seen[dp, path] = 1; adj[dp] = adj[dp] path "\n"; indeg[path]++
        }
      }
      close(path)
    }
    rn = 0
    for (i = 1; i <= n; i++) if (indeg[paths[i]] == 0 && paths[i] != entry) insert_ready(paths[i])
    out = 0
    while (rn > 0) {
      p = ready[1]; for (i = 1; i < rn; i++) ready[i] = ready[i+1]; rn--
      order[++out] = p; done[p] = 1
      nk = split(adj[p], kids, "\n")
      for (k = 1; k <= nk; k++) {
        c = kids[k]; if (c == "") continue
        if (--indeg[c] == 0 && c != entry) insert_ready(c)
      }
    }
    if (entry in indeg) {
      if (indeg[entry] != 0) { printf "%s is part of a use-dependency cycle\n", entry > "/dev/stderr"; exit 1 }
      order[++out] = entry; done[entry] = 1
    }
    if (out != n) {
      print "use-dependency cycle among:" > "/dev/stderr"
      for (i = 1; i <= n; i++) if (!(paths[i] in done)) printf "  %s\n", paths[i] > "/dev/stderr"
      exit 1
    }
    for (i = 1; i <= out; i++) print order[i]
  }'
}

# Finds <module>.silica under $SILICA_STDLIB (first match), or nothing.
find_stdlib_module() {
  [ -n "${SILICA_STDLIB:-}" ] && [ -d "$SILICA_STDLIB" ] || return 0
  find "$SILICA_STDLIB" -type f -name "$1.silica" 2>/dev/null | LC_ALL=C sort | head -n 1
}

# When the project `use`s a module it does not define and no library folder is set, downloads the
# standard library of the selected compiler's release (a compiler set with SILICA_COMPILER has
# no known release, so then nothing is downloaded).
ensure_stdlib() { # ensure_stdlib <build_dir>
  [ -z "${SILICA_STDLIB:-}" ] || return 0
  [ -z "${SILICA_COMPILER:-}" ] && [ -f "$SEL_LINK.release" ] || return 0
  local mod missing=0
  for mod in $(cd "$1" && units=() && while IFS= read -r u; do units+=("$u"); done < .units && used_modules "${units[@]}"); do
    grep -qE "(^|/)$mod\.silica\$" "$1/.units" || { missing=1; break; }
  done
  [ "$missing" = 1 ] || return 0
  install_stdlib_from_release "$(cut -d' ' -f1 "$SEL_LINK.release")" >&2 || return 0
  [ -d "$SILICA_STDLIB_DIR" ] && SILICA_STDLIB="$SILICA_STDLIB_DIR"
}

# FFI wrapper sidecars. The compiler reads a module's `wrapper_meta "<path>"` relative to the
# build directory, so the project's own dangerous_exposure_source/ is mirrored there file by
# file (its folders stay real, so archives built later never land in the source tree). A sidecar
# the project does not provide (a library module's) is taken from SILICA_STDLIB by file name.
link_ffi_sidecars() { # link_ffi_sidecars <root> <build_dir>
  local root="$1" build_dir="$2" f meta lib
  if [ -d "$root/dangerous_exposure_source" ]; then
    while IFS= read -r f; do
      mkdir -p "$build_dir/dangerous_exposure_source/$(dirname "$f")"
      ln -s "$root/dangerous_exposure_source/$f" "$build_dir/dangerous_exposure_source/$f"
    done < <(cd "$root/dangerous_exposure_source" && find . \( -type f -o -type l \) | sed 's|^\./||')
  fi
  [ -n "${SILICA_STDLIB:-}" ] || return 0
  while IFS= read -r meta; do
    case "$meta" in ''|/*|*..*) continue ;; esac
    [ -e "$build_dir/$meta" ] && continue
    lib="$(find "$SILICA_STDLIB" -name "$(basename "$meta")" \( -type f -o -type l \) 2>/dev/null | LC_ALL=C sort | head -n 1)"
    [ -n "$lib" ] || continue
    mkdir -p "$build_dir/$(dirname "$meta")"
    ln -s "$lib" "$build_dir/$meta"
  done < <(cd "$build_dir" && while IFS= read -r u; do
             sed -n 's/^[[:space:]]*wrapper_meta[[:space:]]*"\([^"]*\)".*/\1/p' "$u"
           done < .units | LC_ALL=C sort -u)
}

# Prebuilt FFI archives. The compiler requires dangerous_exposure_source/lib/lib<name>.a for each
# `link_library: "<name>"` a sidecar declares (FFI wrapper specification, silica.link). One the
# project ships is used as it is; a missing one is built from <name>.c beside the sidecar, which is
# how the standard library keeps its C wrappers. With no such source the compiler reports E4034.
build_ffi_archives() { # build_ffi_archives <build_dir> <cc> [cflags...]
  local build_dir="$1" cc="$2" meta real name archive src
  shift 2
  [ -d "$build_dir/dangerous_exposure_source" ] || return 0
  while IFS= read -r meta; do
    real="$meta"
    if [ -L "$real" ]; then
      real="$(readlink "$meta")"
      case "$real" in /*) ;; *) real="$(dirname "$meta")/$real" ;; esac
    fi
    while IFS= read -r name; do
      archive="$build_dir/dangerous_exposure_source/lib/lib$name.a"
      [ -f "$archive" ] && continue
      src="$(dirname "$real")/$name.c"
      [ -f "$src" ] || continue
      command -v ar >/dev/null 2>&1 || die "ar is required to build lib$name.a"
      step Building "lib$name.a"
      mkdir -p "$build_dir/.ffi" "$(dirname "$archive")"
      "$cc" -O2 "$@" -c "$src" -o "$build_dir/.ffi/$name.o" || die "compiling $src failed"
      ar rcs "$archive" "$build_dir/.ffi/$name.o" || die "creating lib$name.a failed"
    done < <(sed -n 's/^[[:space:]]*link_library:[[:space:]]*"\([^"]*\)".*/\1/p' "$meta")
  done < <(find -L "$build_dir/dangerous_exposure_source" -name '*.meta' 2>/dev/null | LC_ALL=C sort)
}

# ---------------------------------------------------------------------------
# build

# Runs the compiler with its output appended to <log>, and meanwhile redraws one Cargo-style
# progress line on the terminal from what the log says so far:
#      Building [=========>               ] 3/10: dangerous_store
# The compiler parses every unit, then compiles them one by one, logging each phase
# ("  Type checking...") and "Finished compiling <unit>" at the end of each. The line is
# erased when the compiler exits. Returns the compiler's exit status.
# Arguments: <log> <unit count> <build dir> <compiler>
COMPILE_PHASES=10  # phases the compiler logs per unit (Module checking … Emitting)
run_with_progress() {
  local log="$1" total="$2" dir="$3" compiler="$4"
  local pid ec cols width=25
  cols="$(tput cols 2>/dev/null || echo 80)"
  (cd "$dir" && exec "$compiler") >> "$log" 2>&1 &
  pid=$!
  # A background job in a script ignores SIGINT, so pass Ctrl-C (and kills) on to it.
  trap 'kill "$pid" 2>/dev/null; printf "\r\033[K" >&2; exit 130' INT TERM

  local frame=0 spin='|/-\'
  while kill -0 "$pid" 2>/dev/null; do
    local done phase parsing unit
    read -r done phase parsing unit < <(awk '
      /^Finished compiling /   { done++; phase = 0; next }
      /^Parsing *$/            { state = "p"; next }
      /^Compiling *$/          { state = "c"; phase = 0; next }
      /\.silica\.\.\.$/        { unit = $0; sub(/\.silica\.\.\.$/, "", unit); sub(/.*\//, "", unit); next }
      /^  [A-Za-z].*\.\.\.$/   { if (state == "c") phase++; next }
      END { printf "%d %d %d %s\n", done, phase, (state != "c"), unit }' "$log" 2>/dev/null)
    : "${done:=0}" "${phase:=0}" "${parsing:=1}"
    [ "$done" -le "$total" ] || done="$total"
    [ "$phase" -lt "$COMPILE_PHASES" ] || phase=$((COMPILE_PHASES - 1))

    # Filled cells: finished units plus the share of the current one.
    local filled=$(( (done * COMPILE_PHASES + phase) * width / (total * COMPILE_PHASES) ))
    [ "$filled" -le "$width" ] || filled="$width"
    local bar="" i=0
    while [ "$i" -lt "$width" ]; do
      if [ "$i" -lt "$filled" ]; then bar="$bar="
      elif [ "$i" -eq "$filled" ]; then bar="$bar>"
      else bar="$bar "; fi
      i=$((i + 1))
    done
    local what="${unit:-}"
    [ "$parsing" = 1 ] && what="parsing${unit:+ $unit}"
    local line
    line="$(printf '[%s] %d/%d %s: %s' "$bar" "$done" "$total" "${spin:$((frame % 4)):1}" "$what")"
    # Keep it to one terminal row so \r can redraw it.
    line="${line:0:$((cols > 14 ? cols - 14 : 1))}"
    printf '\r\033[K%s%12s%s %s' "$c_bold$c_cyan" Building "$c_off" "$line" >&2
    frame=$((frame + 1))
    sleep 0.1
  done
  wait "$pid"; ec=$?
  trap - INT TERM
  printf '\r\033[K' >&2
  return "$ec"
}

# Sets BUILT_EXE to the linked executable. Arguments: <path> <output-or-empty> <verbose 0|1>
build_project() {
  local target="$1" output="$2" verbose="$3"
  local root entry name build_dir

  [ -e "$target" ] || die "no such file or folder: $target"
  target="$(abs_path "$target")"

  if [ -d "$target" ]; then
    root="$target"
    name="$(basename "$root")"
    if [ -f "$root/main.silica" ]; then
      entry="main.silica"
    else
      local candidates
      candidates="$(cd "$root" && grep -lE '^[[:space:]]*fn[[:space:]]+main[[:space:]]*\(' *.silica 2>/dev/null || true)"
      case "$(printf '%s\n' "$candidates" | grep -c .)" in
        1) entry="$candidates" ;;
        0) die "$root has no main.silica (and no top-level .silica file defines fn main)" ;;
        *) die "$root has several files defining fn main; add a main.silica or build one file:
$(printf '  %s\n' $candidates)" ;;
      esac
    fi
  else
    case "$target" in *.silica) ;; *) die "$target is not a .silica file" ;; esac
    root="$(dirname "$target")"
    entry="$(basename "$target")"
    name="${entry%.silica}"
  fi

  # This machine's own target keeps the plain layout; any other target gets its own folder, so
  # building for several targets never mixes their output.
  local machine; machine="$(host_platform)"
  if [ "$SEL_TARGET" = "$machine" ]; then
    build_dir="$root/$BUILD_DIR_NAME/$name"
  else
    build_dir="$root/$BUILD_DIR_NAME/$SEL_TARGET/$name"
  fi
  if [ -z "$SEL_TARGET_PLATFORM" ] && [ -n "$output" ]; then
    die "-o does not apply to $SEL_TARGET: a board target is compiled to assembly only"
  fi
  [ -n "$output" ] || output="$build_dir/$name"
  case "$output" in /*) ;; *) output="$PWD/$output" ;; esac

  local compiler platform="$SEL_TARGET_PLATFORM"
  compiler="$(resolve_compiler)" || exit 1

  # A fresh build directory that mirrors the project through symlinks. The compiler writes
  # .sams/.iface beside each path it reads, so the source tree itself stays untouched.
  rm -rf "$build_dir"
  mkdir -p "$build_dir" || die "cannot create $build_dir"

  local units_file="$build_dir/.units"
  if [ -d "$target" ]; then
    list_units "$root" > "$units_file"
  else
    # A single file: the file itself plus any sibling modules it (transitively) uses.
    printf '%s\n' "$entry" > "$units_file"
    local frontier="$entry" mod
    while [ -n "$frontier" ]; do
      local next=""
      for mod in $(cd "$root" && used_modules $frontier); do
        if [ -f "$root/$mod.silica" ] && ! grep -qxF "$mod.silica" "$units_file"; then
          printf '%s\n' "$mod.silica" >> "$units_file"
          next="$next $mod.silica"
        fi
      done
      frontier="${next# }"
    done
  fi
  [ -s "$units_file" ] || die "no .silica files found in $root"

  local unit
  while IFS= read -r unit; do
    mkdir -p "$build_dir/$(dirname "$unit")"
    ln -s "$root/$unit" "$build_dir/$unit"
  done < "$units_file"

  # Library modules from SILICA_STDLIB for any `use` the project does not satisfy itself.
  ensure_stdlib "$build_dir"
  if [ -n "${SILICA_STDLIB:-}" ] && [ -d "$SILICA_STDLIB" ]; then
    SILICA_STDLIB="$(abs_path "$SILICA_STDLIB")"  # the links below must not be relative
  fi
  if [ -n "${SILICA_STDLIB:-}" ]; then
    local added=1
    while [ "$added" -eq 1 ]; do
      added=0
      local mods
      # Read .units line by line so paths containing spaces stay whole.
      mods="$(cd "$build_dir" && units=() && while IFS= read -r u; do units+=("$u"); done < .units && used_modules "${units[@]}")"
      for mod in $mods; do
        grep -qE "(^|/)$mod\.silica\$" "$units_file" && continue
        local lib; lib="$(find_stdlib_module "$mod")"
        [ -n "$lib" ] || continue
        mkdir -p "$build_dir/.stdlib"
        ln -s "$lib" "$build_dir/.stdlib/$mod.silica"
        printf '%s\n' ".stdlib/$mod.silica" >> "$units_file"
        added=1
      done
    done
  fi

  # The C toolchain for the target: it builds any missing FFI archive now, and assembles and
  # links later. A target other than this machine needs a cross toolchain: CC, or the usual
  # GNU cross compiler for it. A board has no toolchain here; its build stops at assembly.
  local cc asflags ldflags cflags
  cc="${CC:-}"
  if [ -n "$platform" ] && [ "$platform" != "$machine" ] && [ -z "$cc" ]; then
    local candidate
    case "$platform" in
      linux-aarch64) candidate=aarch64-linux-gnu-gcc ;;
      linux-x86_64)  candidate=x86_64-linux-gnu-gcc ;;
      *)             candidate= ;;
    esac
    if [ -n "$candidate" ] && command -v "$candidate" >/dev/null 2>&1; then
      cc="$candidate"
    else
      die "building for $platform on $machine needs a C toolchain that targets $platform to assemble and link; set CC${candidate:+ (for example CC=$candidate)}"
    fi
  fi
  case "$platform" in
    macos-*)
      [ -n "$cc" ] || cc=clang
      asflags=(-mmacosx-version-min="${MACOS_MIN_VERSION:-26.0}")
      cflags=("${asflags[@]}")
      # Entry symbol is `main`; deep recursion wants a larger main-thread stack.
      # shellcheck disable=SC2054  # the commas belong to -Wl, they do not separate elements
      ldflags=(-Wl,-e,main -Wl,-stack_size,0x10000000) ;;
    linux-*)
      [ -n "$cc" ] || cc=cc
      asflags=()
      cflags=(-D_GNU_SOURCE)
      # crt1.o calls main; data tables hold absolute addresses (-no-pie); the failure banner
      # resolves behavior names through dladdr (-rdynamic).
      ldflags=(-no-pie -rdynamic -lpthread) ;;
    '')
      asflags=(); cflags=(); ldflags=() ;;
  esac
  if [ -n "$platform" ]; then
    command -v "$cc" >/dev/null 2>&1 || die "$cc is required to assemble and link Silica programs"
  fi

  link_ffi_sidecars "$root" "$build_dir"
  # A board's FFI archives are built only with a CC for that board.
  if [ -n "$cc" ]; then
    build_ffi_archives "$build_dir" "$cc" ${cflags[@]+"${cflags[@]}"}
  fi

  (cd "$build_dir" && topo_sort .units "$entry") > "$build_dir/silica.config" || die "could not order the modules"
  local count; count="$(grep -c . "$build_dir/silica.config")"
  step Compiling "$name ($count module$([ "$count" = 1 ] || echo s))$([ "$SEL_TARGET" = "$machine" ] || echo " for $SEL_TARGET") with $(basename "$(readlink "$compiler" 2>/dev/null || echo "$compiler")")"

  # Stage 1: silica-compiler reads silica.config from cwd. For multi-unit batches it exits 75/76
  # between units so the OS reclaims memory; re-invoke until it exits 0 or really fails.
  local log="$build_dir/compile.log" ec
  : > "$log"
  while true; do
    if [ "$verbose" = 1 ]; then
      (cd "$build_dir" && "$compiler") 2>&1 | tee -a "$log" >&2; ec="${PIPESTATUS[0]}"
    elif [ -t 2 ]; then
      run_with_progress "$log" "$count" "$build_dir" "$compiler"; ec=$?
    else
      (cd "$build_dir" && "$compiler") >> "$log" 2>&1; ec=$?
    fi
    case "$ec" in
      0) break ;;
      75|76) continue ;;
      *)
        if [ "$verbose" != 1 ]; then
          # Show the diagnostic, not the progress chatter before it or the machine-readable
          # metadata block after it.
          if grep -q '❌' "$log"; then
            sed -n '/❌/,$p' "$log" | sed '/^<!-- SILICA-ERROR-METADATA/,/^-->/d' >&2
          else
            cat "$log" >&2
          fi
        fi
        die "compilation failed (exit $ec); full log: $log" ;;
    esac
  done

  if [ -z "$platform" ]; then
    BUILT_EXE=""
    step Finished "$build_dir (assembly for $SEL_TARGET; assemble, link and flash it with the board's toolchain)"
    return 0
  fi

  # Stage 2: assemble every .sams the compiler produced.
  step Assembling "$name"
  local sams objs=()
  while IFS= read -r sams; do
    local obj="${sams%.sams}.o"
    "$cc" ${asflags[@]+"${asflags[@]}"} -c -x assembler "$build_dir/$sams" -o "$build_dir/$obj" \
      || die "assembling $sams failed"
    objs+=("$build_dir/$obj")
  done < <(cd "$build_dir" && find . -type f -name '*.sams' | sed 's|^\./||' | LC_ALL=C sort)
  [ "${#objs[@]}" -gt 0 ] || die "the compiler produced no assembly"

  # Stage 3: link, plus any archives the program's FFI wrappers declared in silica.link.
  local archives=()
  if [ -f "$build_dir/silica.link" ]; then
    while IFS= read -r a; do
      [ -n "$a" ] || continue
      case "$a" in /*) archives+=("$a") ;; *) archives+=("$build_dir/$a") ;; esac
    done < <(awk -F'"' '/^archive:/ { print $2 }' "$build_dir/silica.link")
  fi

  step Linking "$name"
  mkdir -p "$(dirname "$output")"
  "$cc" "${objs[@]}" ${archives[@]+"${archives[@]}"} ${ldflags[@]+"${ldflags[@]}"} -o "$output" \
    || die "linking failed"

  BUILT_EXE="$output"
  step Finished "$output"
}

# ---------------------------------------------------------------------------
# commands

cmd_build_or_run() {
  local mode="$1"; shift
  local target="" output="" verbose=0 prog_args=() host_opt="" target_opt=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -o|--output) [ $# -ge 2 ] || die "$1 needs a file name"; output="$2"; shift 2 ;;
      --target|--host)
        [ $# -ge 2 ] || die "$1 needs a platform name"
        if [ "$1" = --target ]; then target_opt="$2"; else host_opt="$2"; fi
        shift 2 ;;
      --target=*) target_opt="${1#--target=}"; shift ;;
      --host=*)   host_opt="${1#--host=}"; shift ;;
      -v|--verbose) verbose=1; shift ;;
      -h|--help) usage; exit 0 ;;
      --) shift; prog_args=("$@"); break ;;
      -*) die "unknown option: $1 (see: silica help)" ;;
      *)
        if [ -z "$target" ]; then target="$1"
        elif [ "$mode" = run ]; then prog_args+=("$1")
        else die "unexpected argument: $1"
        fi
        shift ;;
    esac
  done
  [ -n "$target" ] || die "silica $mode needs a .silica file or a project folder"

  select_compiler "$host_opt" "$target_opt"
  if [ "$mode" = run ] && [ -z "$SEL_TARGET_PLATFORM" ]; then
    die "cannot run a $SEL_TARGET program here; use \`silica build --target $SEL_TARGET\` and flash the result with the board's toolchain"
  fi

  BUILT_EXE=""
  build_project "$target" "$output" "$verbose"

  if [ "$mode" = run ]; then
    local ec machine
    step Running "$BUILT_EXE${prog_args[*]+ ${prog_args[*]}}"
    "$BUILT_EXE" ${prog_args[@]+"${prog_args[@]}"}
    ec=$?
    # A program for another platform runs only where the OS can emulate it (binfmt + qemu).
    machine="$(host_platform)"
    if [ "$ec" = 126 ] && [ "$SEL_TARGET_PLATFORM" != "$machine" ]; then
      warn "this $machine machine cannot execute a $SEL_TARGET_PLATFORM program; copy $BUILT_EXE to a $SEL_TARGET_PLATFORM machine and run it there"
    fi
    exit "$ec"
  fi
}

# `silica spec`: plain-text instructions for finding and using the specification. Aimed at
# AI agents, so it is stable, uncoloured, and names absolute paths and exact commands.
cmd_spec() {
  case "${1:-}" in
    '') ;;
    --path) printf '%s\n' "$SILICA_SPEC_DIR"; [ -f "$SILICA_SPEC_DIR/silica-specification.md" ]; return ;;
    -h|--help) echo "Usage: silica spec [--path]"; return 0 ;;
    *) die "unknown option for spec: $1 (expected --path)" ;;
  esac

  local dir="$SILICA_SPEC_DIR" main_spec="$SILICA_SPEC_DIR/silica-specification.md"
  if [ ! -f "$main_spec" ]; then
    cat <<EOF
# Silica specification

Not installed. Expected at: $dir

Install it (with the latest compiler) by running:

    silica update

Then run \`silica spec\` again.
EOF
    return 1
  fi

  local release="" lines listed=""
  lines="$(wc -l < "$main_spec" | tr -d ' ')"
  [ -f "$SILICA_SPEC_VERSION_FILE" ] && release="$(cat "$SILICA_SPEC_VERSION_FILE")"

  cat <<EOF
# Silica specification

The Silica language specification is installed as a flat folder of Markdown files:

    $dir
${release:+
Release: $release. It matches the installed compiler; \`silica update\` refreshes both.
}
## What it is for

Silica is a memory-safe, functional systems language with explicit effects, actors and
region-based memory. It is new and unlikely to be in your training data, so do not guess its
syntax from other languages. Before writing, changing or reviewing Silica code, read the
relevant parts of the specification. The compiler rejects anything the specification does not
allow, including dead bindings, redundant work and missing catch-all arms.

## Where to start

- $main_spec
  The language specification and the source of truth. Use it for syntax, types, effects,
  pattern matching, actors, regions, modules and the standard library.
- $dir/silica-specification-additional.md
  Additional compiler rules: patterns the compiler rejects as errors even though they parse.

silica-specification.md is large ($lines lines). Search it instead of reading it whole.

## How to look things up

- Sections are numbered headings. A compiler error that says \`spec:sect3.6.3\` or
  \`(spec 19.3)\` refers to the heading that starts with that number:

      grep -nE '^#+ 3\\.6\\.3 ' "$main_spec"

  Then read from that line to the next heading of the same level.
- Error codes (E1009, E2008, ...) are explained in the text, often with examples:

      grep -n 'E2008' "$dir"/*.md

- List the table of contents (all section headings):

      grep -nE '^#{2,3} ' "$main_spec"

- Find a keyword or construct across every document:

      grep -n 'sequence proc' "$dir"/*.md

- Links between documents are bare file names in this folder (e.g. ROADMAP.md).

## All documents

EOF
  # The specification and its additional rules first, then everything else by name.
  local f title additional="$dir/silica-specification-additional.md"
  for f in "$main_spec" "$additional" "$dir"/*.md; do
    [ -f "$f" ] || continue
    if [ "$f" = "$main_spec" ] || [ "$f" = "$additional" ]; then
      case " ${listed:-} " in *" $f "*) continue ;; esac
      listed="${listed:-} $f"
    fi
    title="$(sed -n 's/^# //p' "$f" | head -n 1)"
    printf -- '- %s\n  %s\n' "$(basename "$f")" "${title:-(untitled)}"
  done

  cat <<'EOF'

The design documents beside the specification (plans, port notes, runtime designs) explain how
and why things work. The specification wins wherever they disagree.

## Checking your understanding

Compile to confirm that code is valid Silica:

    silica build <file.silica or project folder>
    silica run   <file.silica or project folder>

A failed build prints the error code and specification section to read next.
EOF
}

cmd_version() {
  local compiler
  echo "silica:   $SILICA_CLI_VERSION"
  if [ -n "${SILICA_COMPILER:-}" ]; then
    echo "compiler: $SILICA_COMPILER (from SILICA_COMPILER)"
  elif [ -x "$SILICA_INSTALLED_COMPILER" ]; then
    compiler="$(readlink "$SILICA_INSTALLED_COMPILER" 2>/dev/null || echo silica-compiler)"
    echo "compiler: $SILICA_BIN_DIR/$compiler"
    [ -f "$SILICA_VERSION_FILE" ] && echo "release:  $(cut -d' ' -f1 "$SILICA_VERSION_FILE")"
  else
    echo "compiler: not installed (run: silica update)"
  fi
  local rel name
  for rel in "$SILICA_BIN_DIR"/silica-compiler-*.release; do
    [ -f "$rel" ] && [ -x "${rel%.release}" ] || continue
    name="$(cut -d' ' -f2 "$rel")"
    parse_compiler_asset "$name" || continue
    printf 'cross:    %s/%s (%s on %s, %s)\n' "$SILICA_BIN_DIR" "$name" "$ASSET_TOKEN" "$ASSET_HOST" "$(cut -d' ' -f1 "$rel")"
  done
  if [ -d "$SILICA_SPEC_DIR" ]; then
    echo "spec:     $SILICA_SPEC_DIR"
  else
    echo "spec:     not installed (run: silica update)"
  fi
  if [ -n "${SILICA_STDLIB:-}" ]; then
    echo "stdlib:   $SILICA_STDLIB"
  else
    echo "stdlib:   not installed (run: silica update)"
  fi
  echo "platform: $(host_platform)"
}

# `silica update [--host <platform>] [--target <target>]`
cmd_update() {
  local host_opt="" target_opt=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --target|--host)
        [ $# -ge 2 ] || die "$1 needs a platform name"
        if [ "$1" = --target ]; then target_opt="$2"; else host_opt="$2"; fi
        shift 2 ;;
      --target=*) target_opt="${1#--target=}"; shift ;;
      --host=*)   host_opt="${1#--host=}"; shift ;;
      -h|--help) echo "Usage: silica update [--host <platform>] [--target <target>]"; return 0 ;;
      *) die "unknown option for update: $1 (expected --host or --target)" ;;
    esac
  done
  SEL_LINK=""
  if [ -n "$host_opt$target_opt" ]; then select_compiler "$host_opt" "$target_opt"; fi
  install_latest_release
}

main() {
  [ $# -gt 0 ] || { usage; exit 1; }
  SILICA_ARGS=("$@")  # for "Did you mean" suggestions
  local cmd="$1"; shift
  case "$cmd" in
    build|run)           cmd_build_or_run "$cmd" "$@" ;;
    update)              cmd_update "$@" ;;
    spec)                cmd_spec "$@" ;;
    version|--version)   cmd_version ;;
    help|-h|--help)      usage ;;
    *) printf 'unknown command: %s\n\n' "$cmd" >&2; usage >&2; exit 1 ;;
  esac
}

main "$@"
