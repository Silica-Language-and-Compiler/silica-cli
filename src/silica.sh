#!/usr/bin/env bash
# silica — command line front end for the Silica compiler.
#
#   silica build <file-or-folder>   compile, assemble and link an executable
#   silica run   <file-or-folder>   build, then execute it
#   silica update                   download the latest released compiler
#   silica version                  show which compiler is in use
#
# The compiler binary lives in ~/.silica/bin (override with SILICA_HOME). When it is
# missing, the newest GitHub release is queried and the binary for this machine is
# downloaded. SILICA_COMPILER=/path/to/silica-compiler skips the download entirely.
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
BUILD_DIR_NAME=".silica-build"
# Library modules: SILICA_STDLIB, else ~/.silica/stdlib when it exists.
if [ -z "${SILICA_STDLIB:-}" ] && [ -d "$SILICA_HOME/stdlib" ]; then SILICA_STDLIB="$SILICA_HOME/stdlib"; fi

# ---------------------------------------------------------------------------
# output helpers

if [ -t 2 ]; then
  c_red=$'\033[31m'; c_green=$'\033[32m'; c_dim=$'\033[2m'; c_bold=$'\033[1m'; c_off=$'\033[0m'
else
  c_red=; c_green=; c_dim=; c_bold=; c_off=
fi

die()  { printf '%serror:%s %s\n' "$c_red" "$c_off" "$*" >&2; exit 1; }
info() { printf '%s%s%s\n' "$c_dim" "$*" "$c_off" >&2; }
step() { printf '%s%12s%s %s\n' "$c_green$c_bold" "$1" "$c_off" "$2" >&2; }

usage() {
  cat <<'EOF'
Usage: silica <command> [options] <file-or-folder>

Commands:
  build <path>    Compile <path> (a .silica file or a project folder) to an executable
  run <path>      Build <path>, then execute it (extra args after -- go to the program)
  update          Download the latest released compiler into ~/.silica/bin
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
                    (default: ~/.silica/stdlib, when that folder exists)
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

# Prints "<tag> <asset-name> <download-url>" for this platform's compiler in the latest release.
latest_release_asset() {
  local platform json tag best_name best_url best_num
  platform="$(host_platform)"
  command -v curl >/dev/null 2>&1 || die "curl is required to download the compiler"
  json="$(http_get "https://api.github.com/repos/$SILICA_REPO/releases/latest")" \
    || die "could not query https://github.com/$SILICA_REPO/releases/latest"

  tag="$(printf '%s\n' "$json" | sed -n 's/^ *"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)"
  [ -n "$tag" ] || die "the latest release of $SILICA_REPO has no tag name"

  # Hosted compilers are named silica-<NNNNNN>-<platform>; cross compilers carry an extra
  # emit-target component (silica-NNNNNN-ESP32_S3_raw-<platform>) and are skipped. The
  # numbers count down, so the lowest number is the newest compiler.
  best_name=; best_url=; best_num=
  while IFS= read -r url; do
    local name num
    name="${url##*/}"
    case "$name" in silica-*-"$platform") ;; *) continue ;; esac
    num="${name#silica-}"; num="${num%-"$platform"}"
    case "$num" in ''|*[!0-9]*) continue ;; esac
    if [ -z "$best_num" ] || [ "$num" -lt "$best_num" ]; then
      best_num="$num"; best_name="$name"; best_url="$url"
    fi
  done < <(printf '%s\n' "$json" | sed -n 's/^ *"browser_download_url": *"\([^"]*\)".*/\1/p')

  [ -n "$best_url" ] || die "release $tag has no compiler for $platform"
  printf '%s %s %s\n' "$tag" "$best_name" "$best_url"
}

install_latest_compiler() {
  local tag name url tmp
  read -r tag name url < <(latest_release_asset) || exit 1
  [ -n "${url:-}" ] || exit 1

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

# Prints the compiler path, downloading it first if needed.
resolve_compiler() {
  if [ -n "${SILICA_COMPILER:-}" ]; then
    [ -x "$SILICA_COMPILER" ] || die "SILICA_COMPILER is not an executable file: $SILICA_COMPILER"
    printf '%s\n' "$SILICA_COMPILER"
    return
  fi
  if [ ! -x "$SILICA_INSTALLED_COMPILER" ]; then
    info "no Silica compiler in $SILICA_BIN_DIR; fetching the latest release"
    install_latest_compiler >&2
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
  local cc asflags ldflags
  cc="${CC:-}"
  case "$platform" in
    macos-*)
      [ -n "$cc" ] || cc=clang
      asflags=(-mmacosx-version-min="${MACOS_MIN_VERSION:-26.0}")
      # Entry symbol is `main`; deep recursion wants a larger main-thread stack.
      # shellcheck disable=SC2054  # the commas belong to -Wl, they do not separate elements
      ldflags=(-Wl,-e,main -Wl,-stack_size,0x10000000) ;;
    linux-*)
      [ -n "$cc" ] || cc=cc
      asflags=()
      # crt1.o calls main; data tables hold absolute addresses (-no-pie); the failure banner
      # resolves behavior names through dladdr (-rdynamic).
      ldflags=(-no-pie -rdynamic -lpthread) ;;
  esac
  command -v "$cc" >/dev/null 2>&1 || die "$cc is required to assemble and link Silica programs"

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
  echo "platform: $(host_platform)"
}

main() {
  [ $# -gt 0 ] || { usage; exit 1; }
  local cmd="$1"; shift
  case "$cmd" in
    build|run)           cmd_build_or_run "$cmd" "$@" ;;
    update)              install_latest_compiler ;;
    version|--version)   cmd_version ;;
    help|-h|--help)      usage ;;
    *) printf 'unknown command: %s\n\n' "$cmd" >&2; usage >&2; exit 1 ;;
  esac
}

main "$@"
