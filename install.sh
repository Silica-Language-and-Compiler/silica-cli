#!/usr/bin/env bash
# Installs the `silica` command into ~/.silica/bin (or $SILICA_HOME/bin) and downloads the
# latest released compiler next to it.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SILICA_HOME="${SILICA_HOME:-$HOME/.silica}"
bin="$SILICA_HOME/bin"

mkdir -p "$bin"
ln -sfn "$here/src/silica.sh" "$bin/silica"
chmod +x "$here/src/silica.sh"
echo "Linked $bin/silica -> $here/src/silica.sh"

"$bin/silica" update

case ":$PATH:" in
  *":$bin:"*) ;;
  *)
    echo
    echo "Add Silica to your PATH, e.g. in ~/.zshrc or ~/.bashrc:"
    echo "  export PATH=\"$bin:\$PATH\""
    ;;
esac
