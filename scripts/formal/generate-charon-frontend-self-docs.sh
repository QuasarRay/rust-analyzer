#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

source formal/rust-analyzer-aeneas/toolchain.env

CHARON_BIN="${CHARON_BIN:-charon}"
AENEAS_BIN="${AENEAS_BIN:-aeneas}"
artifact_root="$repo_root/formal/rust-analyzer-aeneas/architectures/charon-frontend/generated"
llbc_dir="$artifact_root/llbc"
manifest_dir="$artifact_root/manifests"
charon_log_dir="$artifact_root/logs/charon"
scratch_root="${FORMAL_SCRATCH_ROOT:-${TMPDIR:-/tmp}/rust-analyzer-charon-frontend-core}"

for tool in cargo git jq sha256sum find sort date awk "$CHARON_BIN" "$AENEAS_BIN"; do
  if [[ "$tool" == */* ]]; then
    [[ -x "$tool" ]] || { echo "missing executable: $tool" >&2; exit 127; }
  else
    command -v "$tool" >/dev/null || { echo "missing executable: $tool" >&2; exit 127; }
  fi
done

rm -rf "$artifact_root"
mkdir -p "$llbc_dir" "$manifest_dir" "$charon_log_dir" "$scratch_root"

unit_jsonl="$scratch_root/units.jsonl"
source_jsonl="$scratch_root/sources.jsonl"
: > "$unit_jsonl"
: > "$source_jsonl"

manifest="$repo_root/crates/rust-analyzer/Cargo.toml"
shared_target="$scratch_root/cargo-target"
mkdir -p "$shared_target"

failures=0
successes=0

extract_target() {
  local kind="$1"
  local name="$2"
  local output="$llbc_dir/rust-analyzer__${kind}__${name}.llbc"
  local log="$charon_log_dir/rust-analyzer__${kind}__${name}.log"
  local -a selector

  case "$kind" in
    lib) selector=(--lib) ;;
    bin) selector=(--bin "$name") ;;
    *) echo "unsupported focused target kind: $kind" >&2; return 64 ;;
  esac

  echo "==> Charon focused self-doc: rust-analyzer [$kind:$name]"
  set +e
  CARGO_TARGET_DIR="$shared_target" "$CHARON_BIN" cargo \
    --preset=aeneas \
    --format=json \
    --dest-file="$output" \
    -- \
    --manifest-path "$manifest" \
    "${selector[@]}" >"$log" 2>&1
  status=$?
  set -e

  if (( status != 0 )) || [[ ! -s "$output" ]]; then
    failures=$((failures + 1))
    rm -f "$output"
    jq -nc \
      --arg package "rust-analyzer" \
      --arg kind "$kind" \
      --arg target "$name" \
      --arg log "${log#"$repo_root"/}" \
      --argjson exit_code "$status" \
      '{package:$package,kind:$kind,target:$target,status:"charon-failed",exit_code:$exit_code,log:$log}' \
      >> "$unit_jsonl"
    return 0
  fi

  successes=$((successes + 1))
  digest="$(sha256sum "$output" | awk '{print $1}')"
  jq -nc \
    --arg package "rust-analyzer" \
    --arg kind "$kind" \
    --arg target "$name" \
    --arg path "${output#"$repo_root"/}" \
    --arg log "${log#"$repo_root"/}" \
    --arg sha256 "$digest" \
    '{package:$package,kind:$kind,target:$target,status:"translated",llbc:{path:$path,sha256:$sha256},log:$log}' \
    >> "$unit_jsonl"
}

# These are the two compiler products that contain the modified architecture:
# the rust-analyzer library and the rust-analyzer executable frontend.
extract_target lib rust_analyzer
extract_target bin rust-analyzer

while IFS= read -r -d '' source_path; do
  digest="$(sha256sum "$source_path" | awk '{print $1}')"
  jq -nc --arg path "$source_path" --arg sha256 "$digest"     '{path:$path,sha256:$sha256}' >> "$source_jsonl"
done < <(git ls-files -z -- ':(glob)crates/rust-analyzer/**/*.rs')

source_commit="$(git rev-parse HEAD)"
generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

jq -s \
  --arg source_commit "$source_commit" \
  --arg generated_at "$generated_at" \
  --arg aeneas_rev "$AENEAS_REV" \
  --arg charon_rev "$CHARON_REV" \
  --argjson failures "$failures" \
  --argjson successes "$successes" \
  '{
    schema:"quasarray.rust-analyzer.charon-frontend-self-docs.v1",
    scope:"crates/rust-analyzer",
    source_commit:$source_commit,
    generated_at_utc:$generated_at,
    aeneas_revision:$aeneas_rev,
    charon_revision:$charon_rev,
    successful_llbc_units:$successes,
    failed_llbc_units:$failures,
    units:.
  }' "$unit_jsonl" > "$manifest_dir/charon-units.json"

jq -s \
  --arg source_commit "$source_commit" \
  --arg generated_at "$generated_at" \
  '{
    schema:"quasarray.rust-analyzer.charon-frontend-source-inventory.v1",
    scope:"crates/rust-analyzer",
    source_commit:$source_commit,
    generated_at_utc:$generated_at,
    rust_sources:.
  }' "$source_jsonl" > "$manifest_dir/rust-sources.json"

# Translate every successfully emitted LLBC with the exact same Aeneas backends
# used by the repository-wide pipeline.
aeneas_status=0
if (( successes > 0 )); then
  set +e
  FORMAL_ARTIFACT_ROOT="$artifact_root" \
  FORMAL_AENEAS_SCRATCH_ROOT="$scratch_root/aeneas" \
  AENEAS_BIN="$AENEAS_BIN" \
    bash scripts/formal/aeneas-e2e.sh
  aeneas_status=$?
  set -e
else
  aeneas_status=3
fi

jq -nc \
  --arg source_commit "$source_commit" \
  --arg generated_at "$generated_at" \
  --arg aeneas_revision "$AENEAS_REV" \
  --arg charon_revision "$CHARON_REV" \
  --argjson charon_failures "$failures" \
  --argjson aeneas_status "$aeneas_status" \
  '{
    schema:"quasarray.rust-analyzer.charon-frontend-provenance.v1",
    source_commit:$source_commit,
    generated_at_utc:$generated_at,
    aeneas_revision:$aeneas_revision,
    charon_revision:$charon_revision,
    producer:"rust-analyzer + pinned Charon",
    consumer:"pinned Aeneas",
    backends:["coq","hol4"],
    charon_failures:$charon_failures,
    aeneas_exit_status:$aeneas_status
  }' > "$manifest_dir/provenance.json"

echo "Dedicated architecture docs: $artifact_root"

if (( failures != 0 || aeneas_status != 0 )); then
  echo "focused self-documentation completed with partial failures: charon=$failures aeneas=$aeneas_status" >&2
  exit 1
fi
