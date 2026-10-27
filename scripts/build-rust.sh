#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
export MACOSX_DEPLOYMENT_TARGET=14.0

if [ -x "$ROOT/.toolchains/cargo/bin/cargo" ]; then
  export PATH="$ROOT/.toolchains/cargo/bin:$PATH"
  export CARGO_HOME="$ROOT/.toolchains/cargo"
  export RUSTUP_HOME="$ROOT/.toolchains/rustup"
elif command -v cargo >/dev/null 2>&1; then
  : # Use the system toolchain without installing or changing user configuration.
else
  echo "cargo not found (checked .toolchains/cargo/bin and PATH)" >&2
  exit 1
fi

cargo build --locked --release --manifest-path "$ROOT/rust/Cargo.toml"
