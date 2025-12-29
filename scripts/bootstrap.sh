#!/usr/bin/env bash
set -euo pipefail

if ! command -v mise >/dev/null 2>&1; then
  echo "ERROR: mise is not installed."
  echo ""
  echo "Install it (official):"
  echo "  curl https://mise.run | sh"
  echo ""
  echo "Then activate it in your shell (bash example):"
  echo "  echo 'eval \"\$(~/.local/bin/mise activate bash)\"' >> ~/.bashrc"
  echo "  source ~/.bashrc"
  exit 1
fi

# Install pinned tools defined in mise.toml
mise install

echo "Toolchain installed."
