//! Charon-backed frontend for Aeneas-compatible LLBC extraction.
//!
//! This deliberately does not reimplement Charon's IR in rust-analyzer. Aeneas
//! pins a specific Charon revision, so the only reliable way to emit the exact
//! contract Aeneas consumes is to execute that Charon revision with its
//! `aeneas` preset.

use std::{
    env, fs,
    io,
    path::{Path, PathBuf},
    process::{Command, ExitStatus},
};

use anyhow::{Context, Result, bail};

use crate::cli::flags;

/// Aeneas revision used by this fork.
pub const AENEAS_REV: &str = "557eff83ecef5083b98a52a94ca7fae63d6c1dab";
/// Charon revision declared by `AENEAS_REV` in Aeneas's upstream `charon-pin`.
pub const CHARON_REV: &str = "c8f15d7d658c86a95658f71ad99cddd4be002e04";

const CHARON_ENV: &str = "RA_CHARON";

#[derive(Debug)]
enum Input {
    Cargo { cwd: PathBuf, manifest: PathBuf },
    Rustc { cwd: PathBuf, source: PathBuf },
}

#[derive(Debug)]
enum Charon {
    Local(PathBuf),
    PinnedNix,
}

impl flags::AeneasLlbc {
    pub fn run(self) -> Result<()> {
        let input = classify_input(&self.path)?;
        let output = absolute_output(&self.output)?;
        let charon = resolve_charon(self.charon_bin.as_deref())?;

        if let Some(parent) = output.parent() {
            fs::create_dir_all(parent)
                .with_context(|| format!("failed to create {}", parent.display()))?;
        }

        let status = run_charon(&charon, &input, &output, &self.compiler_arg)?;
        if !status.success() {
            bail!("Charon failed with status {status}");
        }

        let metadata = fs::metadata(&output)
            .with_context(|| format!("Charon did not produce {}", output.display()))?;
        if !metadata.is_file() || metadata.len() == 0 {
            bail!("Charon produced an empty or non-file LLBC output: {}", output.display());
        }

        println!("{}", output.display());
        eprintln!("Aeneas pin: {AENEAS_REV}");
        eprintln!("Charon pin: {CHARON_REV}");
        Ok(())
    }
}

fn classify_input(path: &Path) -> Result<Input> {
    let path = path
        .canonicalize()
        .with_context(|| format!("failed to canonicalize input {}", path.display()))?;

    if path.is_dir() {
        let manifest = path.join("Cargo.toml");
        if !manifest.is_file() {
            bail!("{} is a directory but contains no Cargo.toml", path.display());
        }
        return Ok(Input::Cargo { cwd: path, manifest });
    }

    if path.file_name().is_some_and(|name| name == "Cargo.toml") {
        let cwd = path
            .parent()
            .context("Cargo.toml has no parent directory")?
            .to_path_buf();
        return Ok(Input::Cargo { cwd, manifest: path });
    }

    if path.extension().is_some_and(|extension| extension == "rs") {
        let cwd = path.parent().context("Rust source has no parent directory")?.to_path_buf();
        return Ok(Input::Rustc { cwd, source: path });
    }

    bail!(
        "input must be a Cargo project directory, Cargo.toml, or a .rs source file: {}",
        path.display()
    )
}

fn absolute_output(path: &Path) -> Result<PathBuf> {
    let path = if path.is_absolute() {
        path.to_path_buf()
    } else {
        env::current_dir().context("failed to get current directory")?.join(path)
    };

    let file_name = path
        .file_name()
        .context("--output must name a file, not a directory")?
        .to_owned();
    let parent = path.parent().context("--output has no parent directory")?;
    fs::create_dir_all(parent)
        .with_context(|| format!("failed to create output directory {}", parent.display()))?;
    let parent = parent
        .canonicalize()
        .with_context(|| format!("failed to canonicalize output directory {}", parent.display()))?;
    Ok(parent.join(file_name))
}

fn resolve_charon(explicit: Option<&Path>) -> Result<Charon> {
    if let Some(path) = explicit {
        verify_local_charon(path, true)?;
        return Ok(Charon::Local(path.to_path_buf()));
    }

    if let Some(path) = env::var_os(CHARON_ENV).map(PathBuf::from) {
        verify_local_charon(&path, true)?;
        return Ok(Charon::Local(path));
    }

    match probe_charon(Path::new("charon"))? {
        Some(version) if compatible_version(&version) => {
            return Ok(Charon::Local(PathBuf::from("charon")));
        }
        Some(version) => {
            eprintln!(
                "ignoring incompatible Charon on PATH ({version}); expected commit {CHARON_REV}"
            );
        }
        None => {}
    }

    match Command::new("nix").arg("--version").output() {
        Ok(output) if output.status.success() => Ok(Charon::PinnedNix),
        Ok(_) => bail!(
            "no compatible Charon found and `nix --version` failed; set --charon-bin or {CHARON_ENV}"
        ),
        Err(error) if error.kind() == io::ErrorKind::NotFound => bail!(
            "no compatible Charon found. Install the pinned Charon, set --charon-bin/{CHARON_ENV}, or install Nix so rust-analyzer can run Aeneas revision {AENEAS_REV}#charon"
        ),
        Err(error) => Err(error).context("failed to probe nix"),
    }
}

fn verify_local_charon(path: &Path, strict: bool) -> Result<()> {
    let Some(version) = probe_charon(path)? else {
        bail!("Charon executable not found: {}", path.display());
    };
    if compatible_version(&version) {
        return Ok(());
    }
    if strict {
        bail!(
            "incompatible Charon at {}: {version}; Aeneas {AENEAS_REV} requires Charon {CHARON_REV}",
            path.display()
        );
    }
    Ok(())
}

fn probe_charon(path: &Path) -> Result<Option<String>> {
    match Command::new(path).arg("--version").output() {
        Ok(output) => {
            if !output.status.success() {
                bail!("{} --version failed with {}", path.display(), output.status);
            }
            let stdout = String::from_utf8_lossy(&output.stdout).trim().to_owned();
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
            let version = if stdout.is_empty() { stderr } else { stdout };
            Ok(Some(version))
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error)
            .with_context(|| format!("failed to execute {} --version", path.display())),
    }
}

fn compatible_version(version: &str) -> bool {
    if version.contains(CHARON_REV) {
        return true;
    }

    version
        .split(|character: char| !character.is_ascii_hexdigit())
        .filter(|token| token.len() >= 7)
        .any(|token| CHARON_REV.starts_with(token))
}

fn run_charon(
    charon: &Charon,
    input: &Input,
    output: &Path,
    compiler_args: &[String],
) -> Result<ExitStatus> {
    let mut command = match charon {
        Charon::Local(path) => Command::new(path),
        Charon::PinnedNix => {
            let mut command = Command::new("nix");
            command
                .arg("run")
                .arg("--accept-flake-config")
                .arg(format!("github:AeneasVerif/aeneas/{AENEAS_REV}#charon"))
                .arg("--");
            command
        }
    };

    let (cwd, args) = charon_args(input, output, compiler_args);
    command.current_dir(&cwd).args(args);

    command
        .status()
        .with_context(|| format!("failed to run Charon for {}", cwd.display()))
}

fn charon_args(input: &Input, output: &Path, compiler_args: &[String]) -> (PathBuf, Vec<String>) {
    let mut args = Vec::new();
    match input {
        Input::Cargo { cwd, manifest } => {
            args.extend([
                "cargo".to_owned(),
                "--preset=aeneas".to_owned(),
                "--format=json".to_owned(),
                "--dest-file".to_owned(),
                output.display().to_string(),
                "--".to_owned(),
                "--manifest-path".to_owned(),
                manifest.display().to_string(),
            ]);
            args.extend(compiler_args.iter().cloned());
            (cwd.clone(), args)
        }
        Input::Rustc { cwd, source } => {
            args.extend([
                "rustc".to_owned(),
                "--preset=aeneas".to_owned(),
                "--format=json".to_owned(),
                "--dest-file".to_owned(),
                output.display().to_string(),
                "--".to_owned(),
                source.display().to_string(),
            ]);
            args.extend(compiler_args.iter().cloned());
            (cwd.clone(), args)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_exact_and_short_charon_commit() {
        assert!(compatible_version(&format!("charon 0.1.0 ({CHARON_REV})")));
        assert!(compatible_version(&format!("charon 0.1.0 ({})", &CHARON_REV[..12])));
        assert!(!compatible_version("charon 0.1.0 (deadbeef)"));
    }

    #[test]
    fn cargo_mode_uses_aeneas_preset_and_json_llbc() {
        let input = Input::Cargo {
            cwd: PathBuf::from("/crate"),
            manifest: PathBuf::from("/crate/Cargo.toml"),
        };
        let output = Path::new("/out/crate.llbc");
        let (_, args) = charon_args(&input, output, &["--all-features".to_owned()]);

        assert_eq!(
            args,
            [
                "cargo",
                "--preset=aeneas",
                "--format=json",
                "--dest-file",
                "/out/crate.llbc",
                "--",
                "--manifest-path",
                "/crate/Cargo.toml",
                "--all-features",
            ]
        );
    }

    #[test]
    fn rustc_mode_uses_same_aeneas_contract() {
        let input = Input::Rustc {
            cwd: PathBuf::from("/crate"),
            source: PathBuf::from("/crate/lib.rs"),
        };
        let output = Path::new("/out/lib.llbc");
        let (_, args) = charon_args(&input, output, &[]);

        assert_eq!(
            args,
            [
                "rustc",
                "--preset=aeneas",
                "--format=json",
                "--dest-file",
                "/out/lib.llbc",
                "--",
                "/crate/lib.rs",
            ]
        );
    }
}
