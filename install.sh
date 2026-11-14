#!/usr/bin/env bash
# Installs the `silica` command into ~/.silica/bin (or $SILICA_HOME/bin) and downloads the
# latest released Silica compiler next to it.
#
#   curl -fsSL https://github.com/Silica-Language-and-Compiler/silica-cli/releases/latest/download/install.sh | bash
#
# Two modes:
#   - piped from curl (or run outside a checkout): downloads the silica-cli release tarball,
#     checks its SHA-256, unpacks it into ~/.silica/cli and links ~/.silica/bin/silica to it.
#   - run from a git checkout (./install.sh): links ~/.silica/bin/silica to this checkout's
#     src/silica.sh, so edits take effect immediately.
#
# Environment:
#   SILICA_HOME         install root (default: ~/.silica)
#   SILICA_CLI_VERSION  release tag to install, e.g. v0.1.0 (default: the latest release)
#   SILICA_CLI_REPO     GitHub repository to install from
#   SILICA_NO_COMPILER  set to 1 to skip downloading the compiler
#   SILICA_CLI_DOWNLOAD_URL  base URL holding silica-cli.tar.gz(.sha256), for testing a build
set -euo pipefail

SILICA_CLI_REPO="${SILICA_CLI_REPO:-Silica-Language-and-Compiler/silica-cli}"
SILICA_HOME="${SILICA_HOME:-$HOME/.silica}"
bin="$SILICA_HOME/bin"
cli_dir="$SILICA_HOME/cli"

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Where this script lives, when it is a file (empty when piped into bash).
here=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
fi

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  else die "need sha256sum or shasum to verify the download"
  fi
}

install_from_release() {
  command -v curl >/dev/null 2>&1 || die "curl is required"
  command -v tar >/dev/null 2>&1 || die "tar is required"

  local base
  if [ -n "${SILICA_CLI_DOWNLOAD_URL:-}" ]; then
    base="${SILICA_CLI_DOWNLOAD_URL%/}"
  elif [ -n "${SILICA_CLI_VERSION:-}" ]; then
    base="https://github.com/$SILICA_CLI_REPO/releases/download/$SILICA_CLI_VERSION"
  else
    base="https://github.com/$SILICA_CLI_REPO/releases/latest/download"
  fi

  local tmp
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/silica-cli-install.XXXXXX")"
  # shellcheck disable=SC2064  # expand $tmp now: it is local to this function
  trap "rm -rf '$tmp'" EXIT

  say "Downloading silica-cli from $base"
  curl -fsSL -o "$tmp/silica-cli.tar.gz" "$base/silica-cli.tar.gz" \
    || die "could not download $base/silica-cli.tar.gz"
  curl -fsSL -o "$tmp/silica-cli.tar.gz.sha256" "$base/silica-cli.tar.gz.sha256" \
    || die "could not download $base/silica-cli.tar.gz.sha256"

  local want got
  want="$(cut -d' ' -f1 < "$tmp/silica-cli.tar.gz.sha256")"
  got="$(sha256_of "$tmp/silica-cli.tar.gz")"
  [ -n "$want" ] && [ "$want" = "$got" ] || die "checksum mismatch for silica-cli.tar.gz (expected $want, got $got)"

  mkdir -p "$tmp/unpacked"
  tar -C "$tmp/unpacked" -xzf "$tmp/silica-cli.tar.gz"
  [ -f "$tmp/unpacked/silica-cli/src/silica.sh" ] || die "the release archive has no silica-cli/src/silica.sh"

  mkdir -p "$SILICA_HOME"
  rm -rf "$cli_dir"
  mv "$tmp/unpacked/silica-cli" "$cli_dir"
  chmod +x "$cli_dir/src/silica.sh"
  src="$cli_dir/src/silica.sh"
}

if [ -n "$here" ] && [ -f "$here/src/silica.sh" ] && [ -z "${SILICA_CLI_VERSION:-}" ]; then
  say "Installing from the checkout at $here"
  chmod +x "$here/src/silica.sh"
  src="$here/src/silica.sh"
else
  install_from_release
fi

mkdir -p "$bin"
ln -sfn "$src" "$bin/silica"
say "Linked $bin/silica -> $src"

if [ "${SILICA_NO_COMPILER:-0}" != 1 ]; then
  "$bin/silica" update
fi

say
"$bin/silica" version

case ":$PATH:" in
  *":$bin:"*) ;;
  *)
    say
    say "Add Silica to your PATH, e.g. in ~/.zshrc or ~/.bashrc:"
    say "  export PATH=\"$bin:\$PATH\""
    ;;
esac
