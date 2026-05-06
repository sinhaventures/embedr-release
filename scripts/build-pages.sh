#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
STATIC_DIR="$ROOT_DIR/site"

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

cp "$ROOT_DIR/install.sh" "$DIST_DIR/install.sh"
cp "$ROOT_DIR/install.ps1" "$DIST_DIR/install.ps1"
cp "$STATIC_DIR/_headers" "$DIST_DIR/_headers"
cp "$STATIC_DIR/_redirects" "$DIST_DIR/_redirects"
cp "$STATIC_DIR/robots.txt" "$DIST_DIR/robots.txt"

chmod 0644 "$DIST_DIR/install.sh" "$DIST_DIR/install.ps1"
