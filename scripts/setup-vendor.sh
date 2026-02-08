#!/bin/bash
# Downloads SQLite amalgamation if not present in vendor/
# Run this before building if vendor/ is empty: ./scripts/setup-vendor.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
VENDOR_DIR="$PROJECT_ROOT/vendor"

SQLITE_VERSION="3490100"
SQLITE_YEAR="2025"
SQLITE_URL="https://sqlite.org/${SQLITE_YEAR}/sqlite-amalgamation-${SQLITE_VERSION}.zip"

if [ -f "$VENDOR_DIR/sqlite3.c" ] && [ -f "$VENDOR_DIR/sqlite3.h" ]; then
    echo "SQLite already present in vendor/"
    exit 0
fi

if ! command -v unzip &> /dev/null; then
    echo "unzip not found, attempting to install..."
    if command -v apt-get &> /dev/null; then
        sudo apt-get update && sudo apt-get install -y unzip
    elif command -v dnf &> /dev/null; then
        sudo dnf install -y unzip
    elif command -v pacman &> /dev/null; then
        sudo pacman -S --noconfirm unzip
    else
        echo "Error: unzip not found and could not determine package manager"
        echo "Please install unzip manually and re-run this script"
        exit 1
    fi
fi

echo "Downloading SQLite amalgamation ${SQLITE_VERSION}..."

mkdir -p "$VENDOR_DIR"
TEMP_ZIP=$(mktemp --suffix=.zip)
trap "rm -f $TEMP_ZIP" EXIT

curl -fSL "$SQLITE_URL" -o "$TEMP_ZIP"

echo "Extracting sqlite3.c and sqlite3.h..."
unzip -j -o "$TEMP_ZIP" "sqlite-amalgamation-${SQLITE_VERSION}/sqlite3.c" -d "$VENDOR_DIR"
unzip -j -o "$TEMP_ZIP" "sqlite-amalgamation-${SQLITE_VERSION}/sqlite3.h" -d "$VENDOR_DIR"

echo "Done. SQLite ${SQLITE_VERSION} installed to vendor/"
