#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

AENEAS_BIN="${AENEAS_BIN:-aeneas}"
artifact_root="${FORMAL_ARTIFACT_ROOT:-$repo_root/formal/rust-analyzer-aeneas/generated}"
llbc_dir="$artifact_root/llbc"
coq_dir="$artifact_root/coq"
hol4_dir="$artifact_root/hol4"
manifest_dir="$artifact_root/manifests"
log_dir="$artifact_root/logs/aeneas"
scratch_root="${FORMAL_AENEAS_SCRATCH_ROOT:-${TMPDIR:-/tmp}/rust-analyzer-aeneas}"

for tool in git jq sha256sum find sort date awk "$AENEAS_BIN"; do
  if [[ "$tool" == */* ]]; then
    [[ -x "$tool" ]] || { echo "missing executable: $tool" >&2; exit 127; }
  else
    command -v "$tool" >/dev/null || { echo "missing executable: $tool" >&2; exit 127; }
  fi
done

[[ -d "$llbc_dir" ]] || { echo "missing LLBC directory: $llbc_dir" >&2; exit 2; }

rm -rf "$coq_dir" "$hol4_dir" "$log_dir" "$scratch_root"
mkdir -p "$coq_dir" "$hol4_dir" "$manifest_dir" "$log_dir" "$scratch_root"

translations_jsonl="$scratch_root/translations.jsonl"
: > "$translations_jsonl"
failures=0
inputs=0

emit_translation() {
  jq -nc "$@" >> "$translations_jsonl"
}

translate_backend() {
  local backend="$1"
  local llbc="$2"
  local stem="$3"
  local output_root log output_files_jsonl output_files_json digest status

  case "$backend" in
    coq) output_root="$coq_dir/$stem" ;;
    hol4) output_root="$hol4_dir/$stem" ;;
    *) echo "unknown backend: $backend" >&2; return 64 ;;
  esac

  mkdir -p "$output_root"
  log="$log_dir/${stem}__${backend}.log"
  output_files_jsonl="$scratch_root/${stem}__${backend}.files.jsonl"
  : > "$output_files_jsonl"

  echo "==> Aeneas: $backend <= ${llbc#"$repo_root"/}"

  set +e
  "$AENEAS_BIN" \
    -backend "$backend" \
    -split-files \
    -no-progress-bar \
    -dest "$output_root" \
    "$llbc" >"$log" 2>&1
  status=$?
  set -e

  digest="$(sha256sum "$llbc" | awk '{print $1}')"

  if (( status != 0 )); then
    failures=$((failures + 1))
    emit_translation \
      --arg unit "$stem" \
      --arg backend "$backend" \
      --arg input "${llbc#"$repo_root"/}" \
      --arg input_sha256 "$digest" \
      --arg log "${log#"$repo_root"/}" \
      --argjson exit_code "$status" \
      '{unit:$unit,backend:$backend,status:"aeneas-failed",exit_code:$exit_code,input:{path:$input,sha256:$input_sha256},log:$log}'
    return 0
  fi

  while IFS= read -r -d '' generated; do
    file_digest="$(sha256sum "$generated" | awk '{print $1}')"
    jq -nc \
      --arg path "${generated#"$repo_root"/}" \
      --arg sha256 "$file_digest" \
      '{path:$path,sha256:$sha256}' >> "$output_files_jsonl"
  done < <(find "$output_root" -type f -print0 | sort -z)

  output_files_json="$(jq -s '.' "$output_files_jsonl")"
  emit_translation \
    --arg unit "$stem" \
    --arg backend "$backend" \
    --arg input "${llbc#"$repo_root"/}" \
    --arg input_sha256 "$digest" \
    --arg log "${log#"$repo_root"/}" \
    --argjson output_files "$output_files_json" \
    '{unit:$unit,backend:$backend,status:"translated",input:{path:$input,sha256:$input_sha256},outputs:$output_files,log:$log}'
}

while IFS= read -r -d '' llbc; do
  inputs=$((inputs + 1))
  filename="$(basename "$llbc")"
  stem="${filename%.llbc}"
  translate_backend coq "$llbc" "$stem"
  translate_backend hol4 "$llbc" "$stem"
done < <(find "$llbc_dir" -maxdepth 1 -type f -name '*.llbc' -print0 | sort -z)

if (( inputs == 0 )); then
  echo "no LLBC inputs found under $llbc_dir" >&2
  exit 3
fi

source_commit="$(git rev-parse HEAD)"
generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

jq -s \
  --arg source_commit "$source_commit" \
  --arg generated_at "$generated_at" \
  --argjson input_units "$inputs" \
  --argjson failures "$failures" \
  '{
    schema:"quasarray.rust-analyzer.aeneas-translations.v1",
    source_commit:$source_commit,
    generated_at_utc:$generated_at,
    input_units:$input_units,
    failures:$failures,
    translations:.
  }' "$translations_jsonl" > "$manifest_dir/aeneas-translations.json"

echo "Rocq/Coq:  $coq_dir"
echo "HOL4:      $hol4_dir"
echo "Manifest:  $manifest_dir/aeneas-translations.json"
echo "Logs:      $log_dir"

if (( failures != 0 )); then
  echo "Aeneas sweep completed with $failures failed translations; see manifest and logs." >&2
  exit 4
fi
