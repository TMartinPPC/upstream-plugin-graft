#!/bin/bash
# Install upstream-plugin-graft: CLI scripts + the bar widget plugin.

set -euo pipefail

BIN_DIR="$HOME/.local/bin"
PLUGIN_ID="io.github.tmartinppc.plugin-graft"
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$PLUGIN_ID"
LINK=1

for arg in "$@"; do
  case "$arg" in
  --copy) LINK=0 ;;
  -h | --help)
    echo "Usage: ./install.sh [--copy]"
    echo ""
    echo "Installs the graft CLI scripts into $BIN_DIR and the plugin into"
    echo "$PLUGIN_DIR."
    echo "  default: the plugin is symlinked (live edit while developing)"
    echo "  --copy : installs a real copy instead"
    exit 0
    ;;
  *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

cd "$(dirname "$0")"

mkdir -p "$BIN_DIR"
for script in bin/omarchy-plugin-graft bin/omarchy-plugin-diverged bin/omarchy-plugin-fork; do
  cp "$script" "$BIN_DIR/$(basename "$script")"
  chmod +x "$BIN_DIR/$(basename "$script")"
  echo "installed $BIN_DIR/$(basename "$script")"
done

mkdir -p "$(dirname "$PLUGIN_DIR")"
if (( LINK )); then
  ln -sfn "$(pwd)/plugin" "$PLUGIN_DIR"
  echo "linked plugin directory into $PLUGIN_DIR"
else
  rm -rf "$PLUGIN_DIR"
  cp -r plugin "$PLUGIN_DIR"
  echo "copied plugin into $PLUGIN_DIR"
fi

echo
echo "Enable it from the Omarchy bar settings (look for 'Plugin Graft'), or run:"
echo "  omarchy-shell shell enablePlugin $PLUGIN_ID right"