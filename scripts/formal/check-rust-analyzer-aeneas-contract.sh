#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

source formal/rust-analyzer-aeneas/toolchain.env

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

crate="$tmp/fixture"
mkdir -p "$crate/src" "$tmp/coq" "$tmp/hol4"

cat > "$crate/Cargo.toml" <<'EOF'
[package]
name = "ra_aeneas_contract_fixture"
version = "0.0.0"
edition = "2024"

[lib]
path = "src/lib.rs"
EOF

cat > "$crate/src/lib.rs" <<'EOF'
pub fn add_one(value: u32) -> u32 {
    value + 1
}
EOF

ra_bin="${RA_BIN:-$repo_root/target/debug/rust-analyzer}"
if [[ ! -x "$ra_bin" ]]; then
  cargo build -p rust-analyzer --bin rust-analyzer
fi

llbc="$tmp/fixture.llbc"
"$ra_bin" aeneas-llbc "$crate" --output "$llbc"

[[ -s "$llbc" ]] || {
  echo "rust-analyzer did not produce LLBC" >&2
  exit 2
}

run_aeneas() {
  if [[ -n "${AENEAS_BIN:-}" ]]; then
    "$AENEAS_BIN" "$@"
  else
    command -v nix >/dev/null || {
      echo "AENEAS_BIN is unset and nix is unavailable" >&2
      exit 127
    }
    nix run --accept-flake-config "github:AeneasVerif/aeneas/${AENEAS_REV}" -- "$@"
  fi
}

run_aeneas -backend coq -dest "$tmp/coq" "$llbc"
run_aeneas -backend hol4 -dest "$tmp/hol4" "$llbc"

find "$tmp/coq" -type f -print -quit | grep -q . || {
  echo "Aeneas Coq/Rocq backend produced no output" >&2
  exit 3
}
find "$tmp/hol4" -type f -print -quit | grep -q . || {
  echo "Aeneas HOL4 backend produced no output" >&2
  exit 4
}

echo "Aeneas contract smoke test passed."
echo "Aeneas: $AENEAS_REV"
echo "Charon:  $CHARON_REV"
