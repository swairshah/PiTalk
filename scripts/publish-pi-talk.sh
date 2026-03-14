#!/usr/bin/env bash
set -euo pipefail

# Publish @swairshah/pi-talk from this repo.
#
# Usage:
#   scripts/publish-pi-talk.sh --dry-run
#   scripts/publish-pi-talk.sh --bump patch
#   scripts/publish-pi-talk.sh --version 1.2.3
#   scripts/publish-pi-talk.sh --bump minor --no-check-clean

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EXT_DIR="$REPO_ROOT/Extensions/pi-talk"

DRY_RUN=0
BUMP=""
TARGET_VERSION=""
CHECK_CLEAN=1

usage() {
  cat <<'EOF'
Publish @swairshah/pi-talk from this repository.

Options:
  --dry-run                Preview package/publish without publishing
  --bump <patch|minor|major>
                           Bump package version before publish
  --version <x.y.z>        Set an explicit package version before publish
  --no-check-clean         Allow publish with a dirty git working tree
  -h, --help               Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --bump)
      BUMP="${2:-}"
      [[ -n "$BUMP" ]] || { echo "Missing value for --bump"; exit 1; }
      shift 2
      ;;
    --version)
      TARGET_VERSION="${2:-}"
      [[ -n "$TARGET_VERSION" ]] || { echo "Missing value for --version"; exit 1; }
      shift 2
      ;;
    --no-check-clean)
      CHECK_CLEAN=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ -n "$BUMP" && -n "$TARGET_VERSION" ]]; then
  echo "Use either --bump or --version, not both."
  exit 1
fi

if [[ ! -d "$EXT_DIR" ]]; then
  echo "Extension directory not found: $EXT_DIR"
  exit 1
fi

command -v npm >/dev/null || { echo "npm not found"; exit 1; }
command -v node >/dev/null || { echo "node not found"; exit 1; }

cd "$REPO_ROOT"

if [[ "$CHECK_CLEAN" -eq 1 ]]; then
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "Git working tree is not clean. Commit/stash first, or use --no-check-clean."
    exit 1
  fi
fi

cd "$EXT_DIR"

CURRENT_VERSION="$(node -p "require('./package.json').version")"
PACKAGE_NAME="$(node -p "require('./package.json').name")"

echo "Package: $PACKAGE_NAME"
echo "Current version: $CURRENT_VERSION"

if [[ -n "$BUMP" ]]; then
  if [[ "$BUMP" != "patch" && "$BUMP" != "minor" && "$BUMP" != "major" ]]; then
    echo "--bump must be one of: patch, minor, major"
    exit 1
  fi
  npm version "$BUMP" --no-git-tag-version >/dev/null
  echo "Bumped version via --bump $BUMP"
elif [[ -n "$TARGET_VERSION" ]]; then
  npm version "$TARGET_VERSION" --no-git-tag-version >/dev/null
  echo "Set version to $TARGET_VERSION"
fi

NEW_VERSION="$(node -p "require('./package.json').version")"
echo "Publish version: $NEW_VERSION"

echo "\nChecking npm auth..."
npm whoami >/dev/null

echo "\nPackage preview (npm pack --dry-run):"
npm pack --dry-run

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "\nDry run complete. No publish executed."
  exit 0
fi

echo "\nPublishing..."
npm publish --access public

echo "\nPublished $PACKAGE_NAME@$NEW_VERSION"
echo "Tip: commit Extensions/pi-talk/package.json (version bump) if changed."
