#!/bin/bash
# Prepare a GhostInTheWSL tagged Windows release.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

error() {
    echo "error: $*" >&2
}

usage() {
    cat <<EOF
Usage: $0 <version>

Examples:
  $0 0.1.3
  $0 v0.1.3

This updates build.zig.zon. Commit, push, and tag with the commands printed
after the update.
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ "$#" -ne 1 ]; then
    usage >&2
    exit 2
fi

version="${1#v}"
tag="v$version"

if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    error "version must be in X.Y.Z or vX.Y.Z format"
    exit 2
fi

cd "$PROJECT_DIR"

if [ -n "$(git status --porcelain)" ]; then
    error "working tree must be clean before preparing a release"
    git status --short
    exit 1
fi

if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    error "tag $tag already exists locally"
    exit 1
fi

current="$(
    sed -n -E 's/^[[:space:]]*\.version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' build.zig.zon |
        head -n 1
)"

if [ -z "$current" ]; then
    error "could not find .version in build.zig.zon"
    exit 1
fi

tmp="$(mktemp)"
awk -v version="$version" '
    /^[[:space:]]*\.version[[:space:]]*=[[:space:]]*"[^"]+",[[:space:]]*$/ && !replaced {
        sub(/"[^"]+"/, "\"" version "\"")
        replaced = 1
    }
    { print }
    END {
        if (!replaced) exit 2
    }
' build.zig.zon >"$tmp" || {
    rm -f "$tmp"
    error "failed to update build.zig.zon"
    exit 1
}
mv "$tmp" build.zig.zon

if command -v zig >/dev/null 2>&1; then
    zig fmt --check build.zig.zon
else
    echo "warning: zig not found; skipped zig fmt --check build.zig.zon" >&2
fi

echo "Updated build.zig.zon: $current -> $version"
echo
echo "Next commands:"
echo "  git add build.zig.zon"
echo "  git commit -m \"build: bump version to $tag\""
echo "  git push origin main"
echo "  git tag -a $tag -m \"$tag\""
echo "  git push origin $tag"
