#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
ARTIFACT_ROOT="$PROJECT_ROOT/third_party/nauterm_mosh_ffi"
SOURCE_REVISION_FILE="$ARTIFACT_ROOT/SOURCE_REVISION"
CHECKSUM_FILE="$ARTIFACT_ROOT/SHA256SUMS"
MOSH_SOURCE_DIR="${1:-}"

if [ ! -s "$SOURCE_REVISION_FILE" ]; then
  echo "Missing pinned Mosh source revision: $SOURCE_REVISION_FILE" >&2
  exit 1
fi

if [ ! -s "$CHECKSUM_FILE" ]; then
  echo "Missing Mosh artifact checksums: $CHECKSUM_FILE" >&2
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  (cd "$PROJECT_ROOT" && sha256sum --check "third_party/nauterm_mosh_ffi/SHA256SUMS")
elif command -v shasum >/dev/null 2>&1; then
  (cd "$PROJECT_ROOT" && shasum -a 256 --check "third_party/nauterm_mosh_ffi/SHA256SUMS")
else
  echo "A SHA-256 checksum utility is required." >&2
  exit 1
fi

assert_file_architecture() {
  local path="$1"
  local expected_pattern="$2"
  local description="$3"
  local details
  details="$(file -b "$path")"
  if ! grep -Eq "$expected_pattern" <<<"$details"; then
    echo "$description has the wrong architecture: $details" >&2
    exit 1
  fi
}

assert_file_architecture \
  "$ARTIFACT_ROOT/linux-x86_64/libnauterm_mosh_ffi.so" \
  'ELF 64-bit.*(x86-64|x86_64)' \
  "Linux x86_64 Mosh library"
assert_file_architecture \
  "$ARTIFACT_ROOT/macos-arm64/libnauterm_mosh_ffi.dylib" \
  'Mach-O 64-bit.*arm64' \
  "macOS arm64 Mosh library"
assert_file_architecture \
  "$ARTIFACT_ROOT/macos-x86_64/libnauterm_mosh_ffi.dylib" \
  'Mach-O 64-bit.*x86_64' \
  "macOS x86_64 Mosh library"
assert_file_architecture \
  "$ARTIFACT_ROOT/windows-x86_64/nauterm_mosh_ffi.dll" \
  'PE32\+.*x86-64' \
  "Windows x86_64 Mosh library"

if [ -n "$MOSH_SOURCE_DIR" ]; then
  expected_revision="$(tr -d '[:space:]' < "$SOURCE_REVISION_FILE")"
  actual_revision="$(git -C "$MOSH_SOURCE_DIR" rev-parse HEAD)"
  if [ "$actual_revision" != "$expected_revision" ]; then
    echo "Mosh source revision mismatch: expected $expected_revision, got $actual_revision" >&2
    exit 1
  fi
fi

echo "Pinned Mosh artifacts verified."
