#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_PNG="$ROOT_DIR/assets/icons/app_icon.png"
SOURCE_COMPOSER_ICON="$ROOT_DIR/assets/icons/Nauterm.icon"
GENERATED_ROOT="$ROOT_DIR/assets/icons/generated"
PNG_DIR="$GENERATED_ROOT/png"
ICONSET_DIR="$GENERATED_ROOT/Nauterm.iconset"
WINDOWS_ICON="$GENERATED_ROOT/app_icon.ico"
SOURCE_HASH_FILE="$GENERATED_ROOT/source.sha256"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "App icon generation requires macOS (sips)." >&2
  exit 1
fi

for command in sips python3 shasum; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Missing icon generation command: $command" >&2
    exit 1
  fi
done

if [[ ! -f "$SOURCE_PNG" ]]; then
  echo "Missing canonical raster app icon: $SOURCE_PNG" >&2
  exit 1
fi
if [[ ! -f "$SOURCE_COMPOSER_ICON/icon.json" ]]; then
  echo "Missing canonical Icon Composer project: $SOURCE_COMPOSER_ICON" >&2
  exit 1
fi

python3 - "$SOURCE_PNG" <<'PY'
from pathlib import Path
import struct
import sys

path = Path(sys.argv[1])
data = path.read_bytes()
if data[:8] != b"\x89PNG\r\n\x1a\n" or len(data) < 24:
    raise SystemExit(f"Canonical app icon is not a valid PNG: {path}")
width, height = struct.unpack(">II", data[16:24])
if (width, height) != (1024, 1024):
    raise SystemExit(
        f"Canonical app icon must be 1024x1024, got {width}x{height}: {path}"
    )
PY

rm -rf "$PNG_DIR" "$ICONSET_DIR"
mkdir -p "$PNG_DIR" "$ICONSET_DIR"

for size in 16 24 32 48 64 128 256 512; do
  sips -z "$size" "$size" "$SOURCE_PNG" \
    --out "$PNG_DIR/app_icon_$size.png" >/dev/null
done
cp "$SOURCE_PNG" "$PNG_DIR/app_icon_1024.png"

cp "$PNG_DIR/app_icon_16.png" "$ICONSET_DIR/icon_16x16.png"
cp "$PNG_DIR/app_icon_32.png" "$ICONSET_DIR/icon_16x16@2x.png"
cp "$PNG_DIR/app_icon_32.png" "$ICONSET_DIR/icon_32x32.png"
cp "$PNG_DIR/app_icon_64.png" "$ICONSET_DIR/icon_32x32@2x.png"
cp "$PNG_DIR/app_icon_128.png" "$ICONSET_DIR/icon_128x128.png"
cp "$PNG_DIR/app_icon_256.png" "$ICONSET_DIR/icon_128x128@2x.png"
cp "$PNG_DIR/app_icon_256.png" "$ICONSET_DIR/icon_256x256.png"
cp "$PNG_DIR/app_icon_512.png" "$ICONSET_DIR/icon_256x256@2x.png"
cp "$PNG_DIR/app_icon_512.png" "$ICONSET_DIR/icon_512x512.png"
cp "$PNG_DIR/app_icon_1024.png" "$ICONSET_DIR/icon_512x512@2x.png"

python3 - "$WINDOWS_ICON" "$PNG_DIR" <<'PY'
from pathlib import Path
import struct
import sys

output = Path(sys.argv[1])
png_dir = Path(sys.argv[2])
sizes = (16, 24, 32, 48, 64, 128, 256)
images = [
    (size, (png_dir / f"app_icon_{size}.png").read_bytes())
    for size in sizes
]

directory = bytearray(struct.pack("<HHH", 0, 1, len(images)))
offset = 6 + 16 * len(images)
payload = bytearray()
for size, image in images:
    encoded_size = 0 if size == 256 else size
    directory.extend(
        struct.pack(
            "<BBBBHHII",
            encoded_size,
            encoded_size,
            0,
            0,
            1,
            32,
            len(image),
            offset,
        )
    )
    payload.extend(image)
    offset += len(image)

output.write_bytes(directory + payload)
PY

source_hash="$(shasum -a 256 "$SOURCE_PNG" | awk '{print $1}')"
printf '%s  assets/icons/app_icon.png\n' "$source_hash" > "$SOURCE_HASH_FILE"

bash "$ROOT_DIR/scripts/prepare_app_icons.sh"
echo "Generated iconset, pixel PNGs, and Windows ICO under assets/icons/generated/."
