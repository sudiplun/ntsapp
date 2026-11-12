#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

echo "=== ntsapp run script ==="
echo "1) Run on connected device (default: android/ios/web)"
echo "2) Run on Linux desktop"
echo
read -rp "Select an option [1-2]: " choice

case "${choice:-1}" in
  1)
    echo ">>> Running on connected device..."
    flutter run --dart-define-from-file=.env
    ;;
  2)
    echo ">>> Running on Linux desktop..."
    flutter run --dart-define-from-file=.env -d linux
    ;;
  *)
    echo "Invalid option: $choice"
    exit 1
    ;;
esac
