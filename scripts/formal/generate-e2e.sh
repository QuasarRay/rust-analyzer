#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

charon_status=0
aeneas_status=0

set +e
scripts/formal/charon-e2e.sh
charon_status=$?
set -e

# Preserve partial progress: Aeneas still translates every LLBC document that
# Charon successfully produced, even if other workspace targets failed.
set +e
scripts/formal/aeneas-e2e.sh
aeneas_status=$?
set -e

if (( charon_status != 0 || aeneas_status != 0 )); then
  echo "formal extraction completed with failures: charon=$charon_status aeneas=$aeneas_status" >&2
  exit 1
fi

echo "formal extraction completed successfully"
