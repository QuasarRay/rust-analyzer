# Charon-enabled rust-analyzer self-documentation

This directory contains a dedicated machine-readable documentation set for the
rust-analyzer architecture that exposes Charon through
`rust-analyzer aeneas-llbc`.

It is intentionally separate from the earlier repository-wide generated tree so
the pre-integration and Charon-enabled architectures can be compared without
overwriting one another.

## Generated contract

The generation path is:

```text
Charon-enabled rust-analyzer source tree
  -> pinned Charon --preset=aeneas --format=json
  -> LLBC JSON
  -> pinned Aeneas
       -> Coq/Rocq .v source
       -> HOL4 .sml source
```

The generated tree is stored under:

```text
formal/rust-analyzer-aeneas/architectures/charon-frontend/generated/
├── llbc/
├── coq/
├── hol4/
├── manifests/
└── logs/
```

The LLBC is the machine-readable semantic source documentation. The Coq/Rocq
and HOL4 directories are translations of exactly those LLBC documents by the
matching pinned Aeneas revision.

No proof search, theorem completion, handwritten model generation, or source
repair is performed. Translation failures are retained in manifests and logs.

## Reproduce locally

```bash
source formal/rust-analyzer-aeneas/toolchain.env
CHARON_BIN=/path/to/matching/charon \
AENEAS_BIN=/path/to/matching/aeneas \
bash scripts/formal/generate-charon-frontend-self-docs.sh
```

The reusable E2E scripts are shared with the earlier documentation pipeline;
only `FORMAL_ARTIFACT_ROOT` and scratch locations are changed. This prevents a
second, drifting implementation of the extraction logic.

## GitHub generation

The dedicated workflow is:

```text
.github/workflows/formal-charon-frontend-self-docs.yml
```

Its persistent form is manual-only (`workflow_dispatch`). Each run commits the
dedicated generated tree back to the selected branch, including partial results
and diagnostics if Charon or Aeneas cannot translate some rust-analyzer targets.
