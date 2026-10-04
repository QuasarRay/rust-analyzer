#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

CHARON_BIN="${CHARON_BIN:-charon}"
artifact_root="${FORMAL_ARTIFACT_ROOT:-$repo_root/formal/rust-analyzer-aeneas/generated}"
llbc_dir="$artifact_root/llbc"
manifest_dir="$artifact_root/manifests"
log_dir="$artifact_root/logs/charon"
scratch_root="${FORMAL_SCRATCH_ROOT:-${TMPDIR:-/tmp}/rust-analyzer-charon}"

for tool in cargo git jq sha256sum base64 awk tr date "$CHARON_BIN"; do
  if [[ "$tool" == */* ]]; then
    [[ -x "$tool" ]] || { echo "missing executable: $tool" >&2; exit 127; }
  else
    command -v "$tool" >/dev/null || { echo "missing executable: $tool" >&2; exit 127; }
  fi
done

rm -rf "$llbc_dir" "$log_dir" "$scratch_root"
mkdir -p "$llbc_dir" "$manifest_dir" "$log_dir" "$scratch_root"

metadata_file="$scratch_root/cargo-metadata.json"
units_jsonl="$scratch_root/units.jsonl"
source_jsonl="$scratch_root/source.jsonl"
: > "$units_jsonl"
: > "$source_jsonl"

cargo metadata --format-version 1 --no-deps > "$metadata_file"

sanitize() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

emit_unit() {
  jq -nc "$@" >> "$units_jsonl"
}

failures=0

mapfile -t packages < <(
  jq -r '
    .workspace_members[] as $member
    | .packages[]
    | select(.id == $member)
    | @base64
  ' "$metadata_file"
)

for package_b64 in "${packages[@]}"; do
  package_json="$(printf '%s' "$package_b64" | base64 --decode)"
  package_name="$(jq -r '.name' <<<"$package_json")"
  package_id="$(jq -r '.id' <<<"$package_json")"
  manifest_path="$(jq -r '.manifest_path' <<<"$package_json")"

  mapfile -t targets < <(jq -r '.targets[] | @base64' <<<"$package_json")

  for target_b64 in "${targets[@]}"; do
    target_json="$(printf '%s' "$target_b64" | base64 --decode)"
    target_name="$(jq -r '.name' <<<"$target_json")"
    target_src="$(jq -r '.src_path' <<<"$target_json")"
    target_kind="$(jq -r '.kind[0]' <<<"$target_json")"

    selector=()
    case "$target_kind" in
      lib|rlib|dylib|cdylib|staticlib|proc-macro)
        selector=(--lib)
        ;;
      bin)
        selector=(--bin "$target_name")
        ;;
      example)
        selector=(--example "$target_name")
        ;;
      test)
        selector=(--test "$target_name")
        ;;
      bench)
        selector=(--bench "$target_name")
        ;;
      custom-build)
        emit_unit \
          --arg package "$package_name" \
          --arg package_id "$package_id" \
          --arg target "$target_name" \
          --arg kind "$target_kind" \
          --arg source "$target_src" \
          '{package:$package,package_id:$package_id,target:$target,kind:$kind,source:$source,status:"recorded-not-standalone-selectable"}'
        continue
        ;;
      *)
        failures=$((failures + 1))
        emit_unit \
          --arg package "$package_name" \
          --arg package_id "$package_id" \
          --arg target "$target_name" \
          --arg kind "$target_kind" \
          --arg source "$target_src" \
          '{package:$package,package_id:$package_id,target:$target,kind:$kind,source:$source,status:"unsupported-cargo-target-kind"}'
        continue
        ;;
    esac

    unit_id="$(sanitize "${package_name}__${target_kind}__${target_name}")"
    output="$llbc_dir/$unit_id.llbc"
    log="$log_dir/$unit_id.log"
    target_dir="$scratch_root/cargo-target/$unit_id"
    mkdir -p "$target_dir"

    echo "==> Charon: $package_name [$target_kind:$target_name]"

    set +e
    CARGO_TARGET_DIR="$target_dir" "$CHARON_BIN" cargo \
      --preset=aeneas \
      --format=json \
      --dest-file="$output" \
      -- \
      --manifest-path "$manifest_path" \
      "${selector[@]}" >"$log" 2>&1
    status=$?
    set -e

    if (( status != 0 )); then
      failures=$((failures + 1))
      rm -f "$output"
      emit_unit \
        --arg package "$package_name" \
        --arg package_id "$package_id" \
        --arg target "$target_name" \
        --arg kind "$target_kind" \
        --arg source "$target_src" \
        --arg log "${log#"$repo_root"/}" \
        --argjson exit_code "$status" \
        '{package:$package,package_id:$package_id,target:$target,kind:$kind,source:$source,status:"charon-failed",exit_code:$exit_code,log:$log}'
      continue
    fi

    if [[ ! -s "$output" ]]; then
      failures=$((failures + 1))
      emit_unit \
        --arg package "$package_name" \
        --arg package_id "$package_id" \
        --arg target "$target_name" \
        --arg kind "$target_kind" \
        --arg source "$target_src" \
        --arg log "${log#"$repo_root"/}" \
        '{package:$package,package_id:$package_id,target:$target,kind:$kind,source:$source,status:"charon-produced-no-llbc",log:$log}'
      continue
    fi

    digest="$(sha256sum "$output" | awk '{print $1}')"
    emit_unit \
      --arg package "$package_name" \
      --arg package_id "$package_id" \
      --arg target "$target_name" \
      --arg kind "$target_kind" \
      --arg source "$target_src" \
      --arg path "${output#"$repo_root"/}" \
      --arg log "${log#"$repo_root"/}" \
      --arg sha256 "$digest" \
      '{package:$package,package_id:$package_id,target:$target,kind:$kind,source:$source,status:"translated",llbc:{path:$path,sha256:$sha256},log:$log}'
  done
done

while IFS= read -r -d '' source_path; do
  digest="$(sha256sum "$source_path" | awk '{print $1}')"
  jq -nc \
    --arg path "$source_path" \
    --arg sha256 "$digest" \
    '{path:$path,sha256:$sha256}' >> "$source_jsonl"
done < <(git ls-files -z -- '*.rs')

source_commit="$(git rev-parse HEAD)"
generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

jq -s \
  --arg source_commit "$source_commit" \
  --arg generated_at "$generated_at" \
  --argjson failures "$failures" \
  '{
    schema:"quasarray.rust-analyzer.charon-units.v1",
    source_commit:$source_commit,
    generated_at_utc:$generated_at,
    failures:$failures,
    units:.
  }' "$units_jsonl" > "$manifest_dir/charon-units.json"

jq -s \
  --arg source_commit "$source_commit" \
  --arg generated_at "$generated_at" \
  '{
    schema:"quasarray.rust-analyzer.rust-source-inventory.v1",
    source_commit:$source_commit,
    generated_at_utc:$generated_at,
    rust_sources:.
  }' "$source_jsonl" > "$manifest_dir/rust-sources.json"

echo "Charon LLBC: $llbc_dir"
echo "Manifests:   $manifest_dir"
echo "Logs:        $log_dir"

if (( failures != 0 )); then
  echo "Charon sweep completed with $failures failed/unsupported targets; see manifest and logs." >&2
  exit 4
fi
