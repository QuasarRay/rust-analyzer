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
CHARON_BIN=/path/to/charon bash scripts/formal/charon-e2e.sh
```

The script uses a fresh Cargo target directory for each target so rustc actually
runs and Charon emits a fresh LLBC document instead of relying on a warm Cargo
cache.

The source inventory includes every tracked `*.rs` file. Cargo
`custom-build` targets are recorded in the manifest but are not invoked as
standalone targets because Cargo has no standalone `--build-script` selector;
they are compiled as part of the owning package when applicable.

## Aeneas translation

After Charon extraction, translate every successfully generated LLBC document
with Aeneas's existing `coq` and `hol4` backends:

```bash
AENEAS_BIN=/path/to/aeneas bash scripts/formal/aeneas-e2e.sh
```

Or run both stages while preserving partial results from each stage:

```bash
CHARON_BIN=/path/to/charon \
AENEAS_BIN=/path/to/aeneas \
bash scripts/formal/generate-e2e.sh
```

Aeneas still names its Rocq-compatible backend `coq`; this pipeline keeps that
upstream backend name and stores its generated `.v` source under `generated/coq/`.
No Rocq or HOL4 checker is invoked.

Compatibility here is a producer/consumer contract guarantee: rust-analyzer emits
the exact LLBC serialization produced by the Charon revision pinned by Aeneas,
and the smoke test verifies that the matching Aeneas binary imports it. This
does not expand Aeneas's supported Rust subset; if Aeneas itself does not
support a Rust construct after importing valid LLBC, this integration leaves
that limitation unchanged.

Each sweep attempts every available unit and backend. Unsupported Rust features
or extraction failures are recorded in JSON manifests and per-unit logs rather
than being repaired with new models or proofs.

## Manual GitHub pipeline

The workflow `.github/workflows/formal-translation.yml` has only a
`workflow_dispatch` trigger. Dispatch it on the branch that should receive the
generated documentation, for example:

```bash
gh workflow run formal-translation.yml --ref <branch>
```

The workflow reads `toolchain.env`, runs the pinned Aeneas revision and its
matching Charon through Nix, executes the E2E translation, and commits
`generated/` back to the same branch. If some targets cannot be translated, it
still commits the partial LLBC/Rocq/HOL4 outputs, manifests, and logs before
reporting a failed workflow result.

The workflow itself is not triggered by pushes or pull requests.


## rust-analyzer as an Aeneas-compatible compiler frontend

This branch exposes Charon directly through the rust-analyzer executable:

```bash
cargo run -p rust-analyzer --bin rust-analyzer -- \
  aeneas-llbc /path/to/crate \
  --output /absolute/or/relative/output.llbc
```

The command accepts a Cargo project directory, a `Cargo.toml`, or an individual
`.rs` file. Cargo projects are compiled through Charon's Cargo/rustc-wrapper
path; individual Rust files are compiled through Charon's rustc-driver path.

rust-analyzer does **not** recreate LLBC from its own HIR or MIR. It invokes the
exact Charon revision pinned by the Aeneas revision in `toolchain.env`, always
with `--preset=aeneas --format=json`. This is intentional: it makes the emitted
file the same serialized Charon contract that Aeneas already consumes, rather
than a rust-analyzer-specific approximation.

Tool selection is strict:

1. `--charon-bin /path/to/charon` is accepted only when `charon version`
   reports the pinned Charon commit.
2. `RA_CHARON` behaves the same way.
3. A matching `charon` on `PATH` is used automatically.
4. Otherwise, when Nix is installed, rust-analyzer runs the Charon package from
   the pinned Aeneas flake revision.

Additional Cargo/rustc arguments may be repeated with `--compiler-arg` and are
forwarded after Charon's `--` separator.

To verify the producer/consumer boundary end to end without proving anything:

```bash
bash scripts/formal/check-rust-analyzer-aeneas-contract.sh
```

That smoke check creates a small Rust crate, emits LLBC through rust-analyzer,
and asks the pinned Aeneas binary to consume that LLBC with both its Coq/Rocq
and HOL4 backends. It only tests extraction/translation compatibility.
