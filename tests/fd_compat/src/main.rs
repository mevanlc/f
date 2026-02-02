use anyhow::{anyhow, bail, Context, Result};
use clap::{Parser, Subcommand};
use regex::Regex;
use serde::Serialize;
use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;

#[derive(Parser)]
#[command(about = "Extract and run a small fd->f compatibility suite from fd's tests.rs")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Extract `te.assert_output(&[...], ...)` argument arrays as JSONL.
    Extract {
        /// Path to fd's `tests/tests.rs`
        #[arg(long)]
        fd_tests: Option<PathBuf>,

        /// Comma-separated allowlist of function names (defaults to a curated list).
        #[arg(long)]
        functions: Option<String>,

        /// Output path (JSONL). If omitted, prints to stdout.
        #[arg(long)]
        out: Option<PathBuf>,
    },

    /// Run extracted cases by comparing `fd <args>` to translated `f <args>`.
    Run {
        /// Path to fd's `tests/tests.rs`
        #[arg(long)]
        fd_tests: Option<PathBuf>,

        /// Path to the f bash script.
        #[arg(long)]
        f: Option<PathBuf>,

        /// `fd` binary to execute.
        #[arg(long, default_value = "fd")]
        fd_bin: String,

        /// Fixture directory to run in (defaults to `tests/fixtures/fd_default` from repo root).
        #[arg(long)]
        fixture: Option<PathBuf>,

        /// Comma-separated allowlist of function names (defaults to a curated list).
        #[arg(long)]
        functions: Option<String>,
    },
}

#[derive(Debug, Clone, Serialize)]
struct Case {
    function: String,
    start_line: usize,
    args: Vec<String>,
}

fn default_fd_tests_path() -> PathBuf {
    if let Ok(home) = std::env::var("HOME") {
        PathBuf::from(home).join("p/my/fd/tests/tests.rs")
    } else {
        PathBuf::from("tests/tests.rs")
    }
}

fn repo_root() -> Result<PathBuf> {
    // We live in: <repo>/tests/fd_compat
    let exe = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let root = exe
        .parent()
        .and_then(|p| p.parent())
        .context("compute repo root from CARGO_MANIFEST_DIR")?;
    Ok(root.to_path_buf())
}

fn default_allowlist() -> BTreeSet<String> {
    [
        // These are either (a) `--glob` focused, or (b) simple regex cases, and
        // they fit the `tests/fixtures/fd_default` tree.
        "test_simple",
        "test_case_insensitive",
        "test_glob_searches",
        "test_full_path_glob_searches",
        "test_hidden",
        "test_no_ignore",
        "test_case_sensitive_glob_searches",
        "test_regex_overrides_glob",
        "test_smart_case_glob_searches",
    ]
    .into_iter()
    .map(|s| s.to_string())
    .collect()
}

fn parse_allowlist(s: Option<String>) -> BTreeSet<String> {
    match s {
        None => default_allowlist(),
        Some(s) => s
            .split(',')
            .map(|p| p.trim())
            .filter(|p| !p.is_empty())
            .map(|p| p.to_string())
            .collect(),
    }
}

fn is_uppercase_sensitive(s: &str) -> bool {
    s.chars().any(|c| matches!(c, 'A'..='Z'))
}

fn normalize_output(stdout: &str) -> String {
    let mut lines: Vec<String> = stdout
        .lines()
        .map(|l| l.trim_end())
        .filter(|l| !l.is_empty())
        .map(|l| l.to_string())
        .collect();
    lines.sort();
    lines.join("\n") + "\n"
}

fn run_cmd(mut cmd: Command) -> Result<String> {
    let out = cmd.output().with_context(|| format!("run command: {cmd:?}"))?;
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr);
        bail!("command failed ({:?}):\n{stderr}", out.status.code());
    }
    Ok(String::from_utf8_lossy(&out.stdout).to_string())
}

fn extract_cases(fd_tests: &Path, allowlist: &BTreeSet<String>) -> Result<(Vec<Case>, Vec<String>)> {
    let content =
        fs::read_to_string(fd_tests).with_context(|| format!("read {}", fd_tests.display()))?;

    let fn_re = Regex::new(r"^\s*(?:pub\s+)?fn\s+([A-Za-z0-9_]+)\s*\(").unwrap();
    let assert_re = Regex::new(r"\bassert_output\s*\(").unwrap();

    let mut current_fn: Option<String> = None;
    let mut cases = Vec::new();
    let mut skipped = Vec::new();

    let mut collecting = false;
    let mut buf = String::new();
    let mut start_line = 0usize;

    for (idx, line) in content.lines().enumerate() {
        let line_no = idx + 1;
        if let Some(cap) = fn_re.captures(line) {
            current_fn = Some(cap[1].to_string());
        }

        if !collecting {
            if assert_re.is_match(line) {
                collecting = true;
                buf.clear();
                start_line = line_no;
            } else {
                continue;
            }
        }

        buf.push_str(line);
        buf.push('\n');

        if collecting && line.contains(");") {
            collecting = false;
            let Some(func) = current_fn.clone() else {
                skipped.push(format!("line {start_line}: no current fn"));
                continue;
            };
            if !allowlist.contains(&func) {
                continue;
            }

            match parse_assert_args(&buf) {
                Ok(args) => cases.push(Case {
                    function: func,
                    start_line,
                    args,
                }),
                Err(e) => skipped.push(format!("{}:{}: {}", fd_tests.display(), start_line, e)),
            }
        }
    }

    Ok((cases, skipped))
}

fn parse_assert_args(call_text: &str) -> Result<Vec<String>> {
    let start = call_text
        .find("&[")
        .ok_or_else(|| anyhow!("no &[...] in assert_output call"))?;
    // `start` points at '&', and `&[` is two bytes. Start scanning *after* `&[`.
    let mut i = start + 2;
    let bytes = call_text.as_bytes();

    let mut depth = 1usize;
    let mut args = Vec::new();
    let mut saw_non_string = false;

    while i < bytes.len() && depth > 0 {
        match bytes[i] {
            b'[' => {
                depth += 1;
                i += 1;
            }
            b']' => {
                depth -= 1;
                i += 1;
            }
            b'"' => {
                let (s, next) = parse_rust_string(call_text, i)?;
                args.push(s);
                i = next;
            }
            b'r' => {
                if let Some((s, next)) = parse_rust_raw_string(call_text, i)? {
                    args.push(s);
                    i = next;
                } else {
                    if depth == 1 && !is_ws_or_comma(bytes[i]) {
                        saw_non_string = true;
                    }
                    i += 1;
                }
            }
            b'(' | b')' | b'{' | b'}' => {
                if depth == 1 {
                    saw_non_string = true;
                }
                i += 1;
            }
            _ => {
                if depth == 1 && !is_ws_or_comma(bytes[i]) {
                    saw_non_string = true;
                }
                i += 1;
            }
        }
    }

    if depth != 0 {
        bail!("unterminated &[...] array");
    }
    if saw_non_string {
        bail!("unsupported non-literal arg(s) in &[...]");
    }
    if args.is_empty() {
        bail!("no string literal args found");
    }
    Ok(args)
}

fn is_ws_or_comma(b: u8) -> bool {
    matches!(b, b' ' | b'\t' | b'\n' | b'\r' | b',')
}

fn parse_rust_raw_string(s: &str, start: usize) -> Result<Option<(String, usize)>> {
    // Supports: r"..." and r#"..."# (any number of #)
    let bytes = s.as_bytes();
    if bytes.get(start) != Some(&b'r') {
        return Ok(None);
    }
    let mut i = start + 1;
    let mut hashes = 0usize;
    while bytes.get(i) == Some(&b'#') {
        hashes += 1;
        i += 1;
    }
    if bytes.get(i) != Some(&b'"') {
        return Ok(None);
    }
    i += 1;
    let content_start = i;
    loop {
        if i >= bytes.len() {
            bail!("unterminated raw string literal");
        }
        if bytes[i] == b'"' {
            let mut j = i + 1;
            let mut ok = true;
            for _ in 0..hashes {
                if bytes.get(j) != Some(&b'#') {
                    ok = false;
                    break;
                }
                j += 1;
            }
            if ok {
                let inner = &s[content_start..i];
                return Ok(Some((inner.to_string(), j)));
            }
        }
        i += 1;
    }
}

fn parse_rust_string(s: &str, start: usize) -> Result<(String, usize)> {
    // start points at the opening '"'
    let bytes = s.as_bytes();
    if bytes.get(start) != Some(&b'"') {
        bail!("internal parse error: expected '\"'");
    }
    let mut i = start + 1;
    let mut out = String::new();
    while i < bytes.len() {
        match bytes[i] {
            b'"' => return Ok((out, i + 1)),
            b'\\' => {
                i += 1;
                if i >= bytes.len() {
                    bail!("unterminated escape");
                }
                match bytes[i] {
                    b'\\' => out.push('\\'),
                    b'"' => out.push('"'),
                    b'n' => out.push('\n'),
                    b'r' => out.push('\r'),
                    b't' => out.push('\t'),
                    b'0' => out.push('\0'),
                    b'x' => {
                        let hex = read_hex(bytes, i + 1, 2)?;
                        out.push(char::from_u32(hex).ok_or_else(|| anyhow!("bad \\x"))?);
                        i += 2;
                    }
                    b'u' => {
                        // \u{...}
                        if bytes.get(i + 1) != Some(&b'{') {
                            bail!("unsupported \\u escape");
                        }
                        let mut j = i + 2;
                        while j < bytes.len() && bytes[j] != b'}' {
                            j += 1;
                        }
                        if j >= bytes.len() {
                            bail!("unterminated \\u{{..}}");
                        }
                        let hex_str = std::str::from_utf8(&bytes[i + 2..j])
                            .context("utf8 in \\u{..}")?;
                        let val = u32::from_str_radix(hex_str, 16)
                            .map_err(|_| anyhow!("bad \\u{{..}}"))?;
                        out.push(char::from_u32(val).ok_or_else(|| anyhow!("bad \\u{{..}}"))?);
                        i = j;
                    }
                    other => {
                        // Minimal set; keep unknown escapes as-is.
                        out.push('\\');
                        out.push(other as char);
                    }
                }
                i += 1;
            }
            b => {
                out.push(b as char);
                i += 1;
            }
        }
    }
    bail!("unterminated string literal");
}

fn read_hex(bytes: &[u8], start: usize, len: usize) -> Result<u32> {
    if start + len > bytes.len() {
        bail!("unterminated hex escape");
    }
    let s = std::str::from_utf8(&bytes[start..start + len]).context("utf8 hex")?;
    u32::from_str_radix(s, 16).map_err(|_| anyhow!("bad hex escape"))
}

#[derive(Default)]
struct ParsedFdArgs {
    flags: Vec<String>,
    and_patterns: Vec<String>,
    pattern: Option<String>,
    paths: Vec<String>,
}

fn parse_fd_invocation(args: &[String]) -> Result<ParsedFdArgs> {
    let mut out = ParsedFdArgs::default();
    let mut i = 0usize;
    while i < args.len() {
        let a = &args[i];
        if a == "--and" {
            let Some(p) = args.get(i + 1) else {
                bail!("--and missing value");
            };
            out.and_patterns.push(p.clone());
            i += 2;
            continue;
        }

        if a.starts_with('-') {
            out.flags.push(a.clone());
            if a == "-t" || a == "--type" || a == "--extension" || a == "-e" {
                let Some(v) = args.get(i + 1) else {
                    bail!("{a} missing value");
                };
                out.flags.push(v.clone());
                i += 2;
                continue;
            }
            i += 1;
            continue;
        }

        if out.pattern.is_none() {
            out.pattern = Some(a.clone());
        } else {
            out.paths.push(a.clone());
        }
        i += 1;
    }
    Ok(out)
}

fn translate_fd_to_f(parsed: &ParsedFdArgs, all_patterns: &[String]) -> Result<Vec<String>> {
    let Some(pattern) = &parsed.pattern else {
        bail!("no pattern");
    };

    let has = |s: &str| parsed.flags.iter().any(|a| a == s);
    let mut f_args: Vec<String> = Vec::new();

    // Match fd's "no auto wrapping" behavior.
    f_args.push("-w".to_string());

    // fd defaults: hidden off, ignore respected, basename-only, smart-case, regex.
    if !has("--hidden") {
        f_args.push("-O".to_string());
    }
    if !has("--no-ignore") && !has("--no-ignore-vcs") {
        f_args.push("-G".to_string());
    }
    if !has("--full-path") {
        f_args.push("-n".to_string());
    }

    // Syntax mode.
    if has("--fixed-strings") {
        f_args.push("-F".to_string());
    } else if has("--regex") {
        f_args.push("-r".to_string());
    } else if has("--glob") {
        // f default is glob
    } else {
        // fd default is regex
        f_args.push("-r".to_string());
    }

    // Case handling.
    // fd precedence: `--ignore-case` overrides `--case-sensitive`.
    if has("--ignore-case") {
        // f default is ignore-case
    } else if has("--case-sensitive") {
        f_args.push("-C".to_string());
    } else if all_patterns.iter().any(|p| is_uppercase_sensitive(p)) {
        // emulate fd smart-case
        f_args.push("-C".to_string());
    }

    // Map a small set of filters we can support.
    let mut i = 0usize;
    while i < parsed.flags.len() {
        let flag = &parsed.flags[i];
        match flag.as_str() {
            "--glob" | "--regex" | "--fixed-strings" | "--full-path" | "--hidden" | "--no-ignore"
            | "--no-ignore-vcs" | "--ignore-case" | "--case-sensitive" => {
                i += 1;
            }
            "-t" | "--type" => {
                let v = parsed
                    .flags
                    .get(i + 1)
                    .ok_or_else(|| anyhow!("{flag} missing value"))?;
                f_args.push("-t".to_string());
                f_args.push(v.clone());
                i += 2;
            }
            "-e" | "--extension" => {
                let v = parsed
                    .flags
                    .get(i + 1)
                    .ok_or_else(|| anyhow!("{flag} missing value"))?;
                f_args.push("-e".to_string());
                f_args.push(v.clone());
                i += 2;
            }
            other => bail!("unsupported flag in fd case: {other}"),
        }
    }

    for ap in &parsed.and_patterns {
        f_args.push("-P".to_string());
        f_args.push(ap.clone());
    }

    f_args.push(pattern.clone());
    for p in &parsed.paths {
        f_args.push(p.clone());
    }
    Ok(f_args)
}

fn main() -> Result<()> {
    let cli = Cli::parse();

    match cli.cmd {
        Cmd::Extract {
            fd_tests,
            functions,
            out,
        } => {
            let allowlist = parse_allowlist(functions);
            let fd_tests = fd_tests.unwrap_or_else(default_fd_tests_path);
            let (cases, skipped) = extract_cases(&fd_tests, &allowlist)?;

            let jsonl = cases
                .into_iter()
                .map(|c| serde_json::to_string(&c).unwrap())
                .collect::<Vec<_>>()
                .join("\n")
                + "\n";

            if let Some(out) = out {
                fs::write(&out, jsonl).with_context(|| format!("write {}", out.display()))?;
            } else {
                print!("{jsonl}");
            }

            if !skipped.is_empty() {
                eprintln!("skipped {} cases:", skipped.len());
                for s in skipped.iter().take(20) {
                    eprintln!("  {s}");
                }
                if skipped.len() > 20 {
                    eprintln!("  ...");
                }
            }
        }

        Cmd::Run {
            fd_tests,
            f,
            fd_bin,
            fixture,
            functions,
        } => {
            let allowlist = parse_allowlist(functions);
            let fd_tests = fd_tests.unwrap_or_else(default_fd_tests_path);

            let root = repo_root()?;
            let fixture = fixture.unwrap_or_else(|| root.join("tests/fixtures/fd_default"));
            let f_path = f.unwrap_or_else(|| root.join("f"));

            if !fixture.is_dir() {
                bail!("fixture directory does not exist: {}", fixture.display());
            }
            if !f_path.is_file() {
                bail!("f script does not exist: {}", f_path.display());
            }

            let (cases, skipped) = extract_cases(&fd_tests, &allowlist)?;
            if !skipped.is_empty() {
                eprintln!("note: skipped {} cases (see `extract` for details)", skipped.len());
            }
            if cases.is_empty() {
                bail!("no cases extracted (check allowlist and fd_tests path)");
            }

            let mut failed = 0usize;
            for (idx, case) in cases.iter().enumerate() {
                let parsed = match parse_fd_invocation(&case.args) {
                    Ok(p) => p,
                    Err(e) => {
                        eprintln!(
                            "SKIP {}:{} ({}) parse fd args: {e}",
                            case.function, case.start_line, idx
                        );
                        continue;
                    }
                };
                let Some(pattern) = parsed.pattern.clone() else {
                    eprintln!(
                        "SKIP {}:{} ({}) no pattern",
                        case.function, case.start_line, idx
                    );
                    continue;
                };
                let mut all_patterns = vec![pattern];
                all_patterns.extend(parsed.and_patterns.clone());

                let f_args = match translate_fd_to_f(&parsed, &all_patterns) {
                    Ok(a) => a,
                    Err(e) => {
                        eprintln!(
                            "SKIP {}:{} ({}) translate: {e}",
                            case.function, case.start_line, idx
                        );
                        continue;
                    }
                };

                let mut fd_cmd = Command::new(&fd_bin);
                fd_cmd.current_dir(&fixture);
                fd_cmd.env("LC_ALL", "C");
                fd_cmd.args(&case.args);

                let mut f_cmd = Command::new(&f_path);
                f_cmd.current_dir(&fixture);
                f_cmd.env("LC_ALL", "C");
                f_cmd.args(&f_args);

                let fd_out = normalize_output(&run_cmd(fd_cmd)?);
                let f_out = normalize_output(&run_cmd(f_cmd)?);

                if fd_out != f_out {
                    failed += 1;
                    eprintln!(
                        "FAIL {}:{}\n  fd: {}\n  f:  {}\n--- fd\n+++ f\n{}",
                        case.function,
                        case.start_line,
                        case.args.join(" "),
                        f_args.join(" "),
                        diff_lines(&fd_out, &f_out)
                    );
                } else {
                    println!("PASS {}:{}", case.function, case.start_line);
                }
            }

            if failed > 0 {
                bail!("{failed} failing cases");
            }
        }
    }

    Ok(())
}

fn diff_lines(expected: &str, actual: &str) -> String {
    // Minimal line diff: show removed/added lines.
    let exp: BTreeSet<&str> = expected.lines().filter(|l| !l.is_empty()).collect();
    let act: BTreeSet<&str> = actual.lines().filter(|l| !l.is_empty()).collect();
    let mut out = String::new();
    for l in exp.difference(&act) {
        out.push_str("-");
        out.push_str(l);
        out.push('\n');
    }
    for l in act.difference(&exp) {
        out.push_str("+");
        out.push_str(l);
        out.push('\n');
    }
    out
}
