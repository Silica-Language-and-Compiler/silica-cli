#!/usr/bin/env bash
# silica — command line front end for the Silica compiler.
#
#   silica build <file-or-folder>   compile, assemble and link an executable
#   silica run   <file-or-folder>   build, then execute it
#   silica update                   download the latest compiler, specification and stdlib
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
  c_red=$'\033[31m'; c_green=$'\033[32m'; c_dim=$'\033[2m'; c_bold=$'\033[1m'; c_off=$'\033[0m'
else
  c_red=; c_green=; c_dim=; c_bold=; c_off=
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
  update          Download the latest released compiler into ~/.silica/bin, the
                  language specification (Markdown) into ~/.silica/spec and the
                  standard library sources into ~/.silica/stdlib
  spec            Explain where the language specification is and how to use it
                  (written for AI agents; --path prints just the folder)
  version         Print the compiler in use and the release it came from
  help            Show this message

Options for build and run:
  -o, --output <file>   Where to write the executable
                        (default: <project>/.silica-build/<name>/<name>)
  -v, --verbose         Show the compiler's full output

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
EOF
}

# ---------------------------------------------------------------------------
# platform detection (mirrors project_makefiles/platform/platforms.mk)

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

# ---------------------------------------------------------------------------
# compiler download

http_get() { # http_get <url> → stdout
  local auth=()
  if [ -n "${GITHUB_TOKEN:-}" ]; then auth=(-H "Authorization: Bearer $GITHUB_TOKEN"); fi
  curl -fsSL -H "Accept: application/vnd.github+json" ${auth[@]+"${auth[@]}"} "$1"
}

# Queries the latest release once and sets:
#   REL_TAG                       the release tag
#   REL_COMPILER_NAME/_URL        this platform's compiler asset
#   REL_SPEC_URL                  silica-specification.zip (empty when the release has none)
query_latest_release() {
  local platform json best_num url name num
  platform="$(host_platform)"
  command -v curl >/dev/null 2>&1 || die "curl is required to download the compiler"
  json="$(http_get "https://api.github.com/repos/$SILICA_REPO/releases/latest")" \
    || die "could not query https://github.com/$SILICA_REPO/releases/latest"

  REL_TAG="$(printf '%s\n' "$json" | sed -n 's/^ *"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)"
  [ -n "$REL_TAG" ] || die "the latest release of $SILICA_REPO has no tag name"

  # Hosted compilers are named silica-<NNNNNN>-<platform>; cross compilers carry an extra
  # emit-target component (silica-NNNNNN-ESP32_S3_raw-<platform>) and are skipped. The
  # numbers count down, so the lowest number is the newest compiler.
  REL_COMPILER_NAME=; REL_COMPILER_URL=; REL_SPEC_URL=; best_num=
  while IFS= read -r url; do
    name="${url##*/}"
    if [ "$name" = silica-specification.zip ]; then REL_SPEC_URL="$url"; continue; fi
    case "$name" in silica-*-"$platform") ;; *) continue ;; esac
    num="${name#silica-}"; num="${num%-"$platform"}"
    case "$num" in ''|*[!0-9]*) continue ;; esac
    if [ -z "$best_num" ] || [ "$num" -lt "$best_num" ]; then
      best_num="$num"; REL_COMPILER_NAME="$name"; REL_COMPILER_URL="$url"
    fi
  done < <(printf '%s\n' "$json" | sed -n 's/^ *"browser_download_url": *"\([^"]*\)".*/\1/p')

  [ -n "$REL_COMPILER_URL" ] || die "release $REL_TAG has no compiler for $platform"
}

install_compiler_from_release() {
  local tag="$REL_TAG" name="$REL_COMPILER_NAME" url="$REL_COMPILER_URL" tmp

  if [ -x "$SILICA_INSTALLED_COMPILER" ] && [ -f "$SILICA_VERSION_FILE" ] \
     && [ "$(cat "$SILICA_VERSION_FILE")" = "$tag $name" ]; then
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
  ln -sfn "$name" "$SILICA_INSTALLED_COMPILER"
  printf '%s %s\n' "$tag" "$name" > "$SILICA_VERSION_FILE"
  step Installed "$SILICA_INSTALLED_COMPILER -> $name"
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

# `silica update`, and the first build: compiler, specification and standard library from the
# latest release. A specification or library failure is reported but only fails `silica update`.
install_latest_release() {
  local ec=0
  query_latest_release
  install_compiler_from_release
  install_spec_from_release || ec=1
  install_stdlib_from_release "$REL_TAG" || ec=1
  return "$ec"
}

# Prints the compiler path, downloading it first if needed.
resolve_compiler() {
  if [ -n "${SILICA_COMPILER:-}" ]; then
    [ -x "$SILICA_COMPILER" ] || die "SILICA_COMPILER is not an executable file: $SILICA_COMPILER"
    printf '%s\n' "$SILICA_COMPILER"
    return
  fi
  if [ ! -x "$SILICA_INSTALLED_COMPILER" ]; then
    info "no Silica compiler in $SILICA_BIN_DIR; fetching the latest release"
    install_latest_release >&2 || true
  fi
  printf '%s\n' "$SILICA_INSTALLED_COMPILER"
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
# standard library of the installed compiler's release (a compiler set with SILICA_COMPILER has
# no known release, so then nothing is downloaded).
ensure_stdlib() { # ensure_stdlib <build_dir>
  [ -z "${SILICA_STDLIB:-}" ] || return 0
  [ -z "${SILICA_COMPILER:-}" ] && [ -f "$SILICA_VERSION_FILE" ] || return 0
  local mod missing=0
  for mod in $(cd "$1" && units=() && while IFS= read -r u; do units+=("$u"); done < .units && used_modules "${units[@]}"); do
    grep -qE "(^|/)$mod\.silica\$" "$1/.units" || { missing=1; break; }
  done
  [ "$missing" = 1 ] || return 0
  install_stdlib_from_release "$(cut -d' ' -f1 "$SILICA_VERSION_FILE")" >&2 || return 0
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

  build_dir="$root/$BUILD_DIR_NAME/$name"
  [ -n "$output" ] || output="$build_dir/$name"
  case "$output" in /*) ;; *) output="$PWD/$output" ;; esac

  local compiler platform
  compiler="$(resolve_compiler)" || exit 1
  platform="$(host_platform)"

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

  # The C toolchain: it builds any missing FFI archive now, and assembles and links later.
  local cc asflags ldflags cflags
  cc="${CC:-}"
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
  esac
  command -v "$cc" >/dev/null 2>&1 || die "$cc is required to assemble and link Silica programs"

  link_ffi_sidecars "$root" "$build_dir"
  build_ffi_archives "$build_dir" "$cc" ${cflags[@]+"${cflags[@]}"}

  (cd "$build_dir" && topo_sort .units "$entry") > "$build_dir/silica.config" || die "could not order the modules"
  local count; count="$(grep -c . "$build_dir/silica.config")"
  step Compiling "$name ($count module$([ "$count" = 1 ] || echo s)) with $(basename "$(readlink "$compiler" 2>/dev/null || echo "$compiler")")"

  # Stage 1: silica-compiler reads silica.config from cwd. For multi-unit batches it exits 75/76
  # between units so the OS reclaims memory; re-invoke until it exits 0 or really fails.
  local log="$build_dir/compile.log" ec
  : > "$log"
  while true; do
    if [ "$verbose" = 1 ]; then
      (cd "$build_dir" && "$compiler") 2>&1 | tee -a "$log" >&2; ec="${PIPESTATUS[0]}"
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
  local target="" output="" verbose=0 prog_args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      -o|--output) [ $# -ge 2 ] || die "$1 needs a file name"; output="$2"; shift 2 ;;
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

  BUILT_EXE=""
  build_project "$target" "$output" "$verbose"

  if [ "$mode" = run ]; then
    step Running "$BUILT_EXE${prog_args[*]+ ${prog_args[*]}}"
    "$BUILT_EXE" ${prog_args[@]+"${prog_args[@]}"}
    exit $?
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

main() {
  [ $# -gt 0 ] || { usage; exit 1; }
  local cmd="$1"; shift
  case "$cmd" in
    build|run)           cmd_build_or_run "$cmd" "$@" ;;
    update)              install_latest_release ;;
    spec)                cmd_spec "$@" ;;
    version|--version)   cmd_version ;;
    help|-h|--help)      usage ;;
    *) printf 'unknown command: %s\n\n' "$cmd" >&2; usage >&2; exit 1 ;;
  esac
}

main "$@"
