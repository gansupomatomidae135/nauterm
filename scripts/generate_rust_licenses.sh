#!/usr/bin/env sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mosh_dir=${NAUTERM_MOSH_SOURCE_DIR:-"$project_dir/../nauterm-mosh"}
config="$project_dir/licenses/about.toml"
template="$project_dir/licenses/rust-licenses.hbs"
output_dir="$project_dir/assets/licenses"

if ! command -v cargo-about >/dev/null 2>&1; then
  echo "cargo-about is required: cargo install --locked --version 0.9.1 --features cli cargo-about" >&2
  exit 1
fi

if [ ! -f "$mosh_dir/Cargo.toml" ]; then
  echo "nauterm-mosh source not found at $mosh_dir" >&2
  exit 1
fi

mkdir -p "$output_dir"

cargo about generate \
  --all-features \
  --locked \
  --fail \
  --config "$config" \
  --manifest-path "$project_dir/native/nauterm_ffi/Cargo.toml" \
  "$template" \
  -o "$output_dir/nauterm-rust.json"

cargo about generate \
  --all-features \
  --locked \
  --fail \
  --config "$config" \
  --manifest-path "$mosh_dir/Cargo.toml" \
  "$template" \
  -o "$output_dir/nauterm-mosh-rust.json"

echo "Generated Rust license notices in $output_dir"
