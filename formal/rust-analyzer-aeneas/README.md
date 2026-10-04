# rust-analyzer → Charon → Aeneas artifacts

This directory is reserved for machine-generated semantic artifacts for this
rust-analyzer fork.

## Scope

The pipeline is intentionally translation-only:

1. Charon compiles each selectable Cargo workspace target and serializes its
   LLBC representation as JSON.
2. Aeneas consumes those LLBC files and emits Rocq/Coq and HOL4 source.
3. The generated artifacts are stored under `generated/` in this repository.

The pipeline does **not** attempt to prove, complete, repair, transform, or
otherwise develop the generated proof-assistant source. External-definition
templates, unsupported Rust constructs, and translation failures remain visible
as tool output rather than being filled in by handwritten models.

## Why LLBC is the machine-readable documentation

Charon is an extraction layer over rustc. Its serialized LLBC contains crate
types, functions, globals, trait declarations/implementations, simplified MIR
bodies, source information, and semantic metadata. Aeneas consumes this same
serialized representation directly. Keeping LLBC as the documentation format
therefore avoids inventing an intermediate schema that Aeneas cannot consume.

## Layout

```text
formal/rust-analyzer-aeneas/
├── README.md
├── toolchain.env
└── generated/
    ├── llbc/       # Charon JSON LLBC documents
    ├── coq/        # added by the Aeneas backend stage
    ├── hol4/       # added by the Aeneas backend stage
    └── manifests/  # source/translation provenance
```

Generated contents are replaced by each complete pipeline run. The scripts use
absolute output paths because Charon output path handling is sensitive to the
Cargo workspace root.

## Local extraction

Prerequisites: `bash`, `cargo`, `git`, `jq`, `sha256sum`, and a Charon
binary compatible with the pinned Aeneas revision.

```bash
CHARON_BIN=/path/to/charon scripts/formal/charon-e2e.sh
```

The script uses a fresh Cargo target directory for each target so rustc actually
runs and Charon emits a fresh LLBC document instead of relying on a warm Cargo
cache.

The source inventory includes every tracked `*.rs` file. Cargo
`custom-build` targets are recorded in the manifest but are not invoked as
standalone targets because Cargo has no standalone `--build-script` selector;
they are compiled as part of the owning package when applicable.
