#!/usr/bin/env bash
#
# Build helper for the NoteSafe app.
#
#   ./build.sh linux      Linux desktop bundle
#   ./build.sh android    Android release APKs, split per ABI
#   ./build.sh all        Linux + Android
#   ./build.sh clean      flutter clean
#
# The Supabase URL/key are compiled into the app from the .env file.
# Point it somewhere else with ENV_FILE=path/to/other.env.

set -euo pipefail

cd "$(dirname "$0")"

ENV_FILE="${ENV_FILE:-.env}"
BUILD_MODE="release"
TARGET=""
# The targets built in this run, used for the artifact summary.
BUILT=""

# --- helpers -----------------------------------------------------------------

usage() {
  cat <<EOF
=== ntsapp build script ===

Usage: ./build.sh <command> [--debug]

Commands:
  linux      Build the Linux desktop bundle
  android    Build the Android release APKs, split per ABI
  all        Build Linux and Android
  clean      Remove the build output
  help       Show this message

Options:
  --debug    Build the debug profile instead of release

Environment:
  ENV_FILE   Dart-define file holding SUPABASE_URL / SUPABASE_KEY
             (default: .env)
EOF
}

log() { printf '\n\033[1m>>> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mWarning: %s\033[0m\n' "$*"; }
fail() { printf '\033[31mError: %s\033[0m\n' "$*" >&2; exit 1; }

require_flutter() {
  command -v flutter >/dev/null 2>&1 ||
    fail "flutter is not on the PATH - see https://docs.flutter.dev/get-started/install"
}

# The app reads the Supabase URL and key from dart-defines. Without them the
# build still succeeds, but the app cannot reach the server and never syncs.
require_env() {
  if [ ! -f "$ENV_FILE" ]; then
    fail "$ENV_FILE not found.
       It holds the Supabase settings that are compiled into the app:
         SUPABASE_URL=https://<project>.supabase.co
         SUPABASE_KEY=<publishable key>
       Create it (it is git ignored) or point ENV_FILE somewhere else."
  fi
  grep -q '^SUPABASE_URL=' "$ENV_FILE" || fail "$ENV_FILE has no SUPABASE_URL"
  grep -q '^SUPABASE_KEY=' "$ENV_FILE" || fail "$ENV_FILE has no SUPABASE_KEY"
}

# --- targets -----------------------------------------------------------------

build_linux() {
  log "Building Linux ($BUILD_MODE)"
  flutter build linux "--$BUILD_MODE" --dart-define-from-file="$ENV_FILE"
  BUILT="$BUILT linux"
}

build_android() {
  log "Building Android ($BUILD_MODE, split per ABI)"
  # A split build does not produce a universal APK, but an earlier
  # non-split build leaves one behind - remove it so nobody ships it by
  # accident.
  rm -f build/app/outputs/flutter-apk/*.apk
  flutter build apk "--$BUILD_MODE" --split-per-abi \
    --dart-define-from-file="$ENV_FILE"
  BUILT="$BUILT android"
}

clean() {
  log "Cleaning"
  flutter clean
}

# --- summary -----------------------------------------------------------------

show_artifacts() {
  local found=0
  local file

  log "Artifacts"

  case " $BUILT " in
  *" linux "*)
    file="build/linux/x64/$BUILD_MODE/bundle/notesafe"
    if [ -f "$file" ]; then
      found=1
      printf '  %-58s %s\n' "$file" "$(du -h "$file" | cut -f1)"
    fi
    ;;
  esac

  case " $BUILT " in
  *" android "*)
    for file in build/app/outputs/flutter-apk/*-"$BUILD_MODE".apk; do
      if [ -f "$file" ]; then
        found=1
        printf '  %-58s %s\n' "$file" "$(du -h "$file" | cut -f1)"
      fi
    done
    ;;
  esac

  if [ "$found" -eq 0 ]; then
    warn "no artifacts found"
    return
  fi

  echo
  case " $BUILT " in
  *" linux "*)
    echo "  Linux:   build/linux/x64/$BUILD_MODE/bundle/notesafe"
    ;;
  esac
  case " $BUILT " in
  *" android "*)
    echo "  Android: build/app/outputs/flutter-apk/"
    ;;
  esac
}

# --- entry point -------------------------------------------------------------

for arg in "$@"; do
  case "$arg" in
    --debug)
      BUILD_MODE="debug"
      ;;
    --release)
      BUILD_MODE="release"
      ;;
    -h | --help | help)
      usage
      exit 0
      ;;
    linux | android | all | clean)
      TARGET="$arg"
      ;;
    *)
      usage
      fail "unknown command: $arg"
      ;;
  esac
done

if [ -z "$TARGET" ]; then
  usage
  exit 1
fi

require_flutter

case "$TARGET" in
  clean)
    clean
    ;;
  linux)
    require_env
    build_linux
    show_artifacts
    ;;
  android)
    require_env
    build_android
    show_artifacts
    ;;
  all)
    require_env
    build_linux
    build_android
    show_artifacts
    ;;
esac
