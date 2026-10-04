#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

artifact_root="$repo_root/formal/rust-analyzer-aeneas/architectures/charon-frontend/generated"

export FORMAL_ARTIFACT_ROOT="$artifact_root"
export FORMAL_SCRATCH_ROOT="${FORMAL_SCRATCH_ROOT:-${TMPDIR:-/tmp}/rust-analyzer-charon-frontend-charon}"
export FORMAL_AENEAS_SCRATCH_ROOT="${FORMAL_AENEAS_SCRATCH_ROOT:-${TMPDIR:-/tmp}/rust-analyzer-charon-frontend-aeneas}"

bash scripts/formal/generate-e2e.sh
