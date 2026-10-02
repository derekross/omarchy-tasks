//! omarchy-taskbridge: the small command the Omarchy Tasks plugin runs
//! instead of talking to `task` directly. Every call prints one JSON object.
//!
//!   omarchy-taskbridge snapshot [--waiting] [--filters <json>]
//!                                                 pending tasks, counts, projects, filters
//!   omarchy-taskbridge add <words…>                task add …
//!   omarchy-taskbridge done <uuid>                 task <uuid> done
//!   omarchy-taskbridge modify <uuid> <changes…>    task <uuid> modify due:… +tag …
//!   omarchy-taskbridge undo                        task undo
//!   omarchy-taskbridge sync                        task sync, if a server is configured
//!   omarchy-taskbridge version
//!
//! `task` runs in its own process group with a hard timeout, stdin closed,
//! and confirmation, colour and chatter turned off, so a stuck database or
//! a lingering hook can never hang the shell.

use std::io::Read;
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use anyhow::{Context, Result, anyhow};
use chrono::Local;
use serde_json::{Value, json};
use taskbridge::{
    FilterOut, RawTask, build_snapshot_filtered, is_allowed_add_word, is_allowed_modification,
    is_uuid, parse_filters, unavailable,
};

const TIMEOUT: Duration = Duration::from_secs(8);
const SYNC_TIMEOUT: Duration = Duration::from_secs(60);
const GRACE: Duration = Duration::from_millis(500);
const MAX_OUTPUT: u64 = 4 * 1024 * 1024;

/// Overrides for every `task` call. `rc.gc=0` keeps IDs stable between the
/// export and the action the user takes on what they saw.
const RC: [&str; 5] = [
    "rc.verbose=nothing",
    "rc.color=off",
    "rc.confirmation=off",
    "rc.bulk=0",
    "rc.gc=0",
];

/// Taskwarrior 3 sync backends. Sync is skipped unless one is configured.
const SYNC_SETTINGS: [&str; 4] = [
    "rc.sync.server.url",
    "rc.sync.local.server_dir",
    "rc.sync.gcp.bucket",
    "rc.sync.aws.bucket",
];

struct Captured {
    text: String,
    truncated: bool,
}

struct Output {
    status: Option<i32>,
    stdout: String,
    stdout_truncated: bool,
    stderr: String,
}

/// Drain a pipe on its own thread so a chatty `task` can't deadlock us.
/// Past the cap the rest is discarded rather than left in the pipe, which
/// would block `task` until the timeout.
fn read_all(mut pipe: impl Read + Send + 'static) -> mpsc::Receiver<Captured> {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let mut buf = Vec::new();
        let _ = pipe.by_ref().take(MAX_OUTPUT).read_to_end(&mut buf);
        let truncated = buf.len() as u64 >= MAX_OUTPUT;
        if truncated {
            let _ = std::io::copy(&mut pipe, &mut std::io::sink());
        }
        let _ = tx.send(Captured { text: String::from_utf8_lossy(&buf).into_owned(), truncated });
    });
    rx
}

fn signal_group(pid: i32, signal: i32) {
    // SAFETY: killpg is a plain syscall on a pid we spawned with its own
    // group; a stale pid can only fail with ESRCH.
    unsafe {
        libc::killpg(pid, signal);
    }
}

fn run_task(args: &[&str], timeout: Duration) -> Result<Output> {
    let mut child = Command::new("task")
        .args(RC)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .process_group(0)
        .spawn()
        .context("could not start task")?;
    let pid = child.id() as i32;
    let out_rx = read_all(child.stdout.take().context("no stdout")?);
    let err_rx = read_all(child.stderr.take().context("no stderr")?);

    let started = Instant::now();
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break status.code();
        }
        if started.elapsed() > timeout {
            // Everything in the group: task and anything its hooks started.
            signal_group(pid, libc::SIGTERM);
            let grace = Instant::now();
            while grace.elapsed() < GRACE && child.try_wait()?.is_none() {
                std::thread::sleep(Duration::from_millis(20));
            }
            if child.try_wait()?.is_none() {
                signal_group(pid, libc::SIGKILL);
                let _ = child.wait();
            }
            return Err(anyhow!("task took longer than {}s", timeout.as_secs()));
        }
        std::thread::sleep(Duration::from_millis(20));
    };

    // If a background process inherited the pipe, don't wait on it forever.
    let remaining = timeout.saturating_sub(started.elapsed()).max(GRACE);
    let stdout = out_rx
        .recv_timeout(remaining)
        .map_err(|_| anyhow!("task exited but something it started still holds its output"))?;
    let stderr = err_rx.recv_timeout(GRACE).map(|c| c.text).unwrap_or_default();
    Ok(Output { status, stdout: stdout.text, stdout_truncated: stdout.truncated, stderr })
}

fn task_available() -> bool {
    std::env::var_os("PATH")
        .map(|paths| std::env::split_paths(&paths).any(|dir| dir.join("task").is_file()))
        .unwrap_or(false)
}

fn task_version() -> String {
    run_task(&["_version"], Duration::from_secs(3))
        .map(|o| o.stdout.trim().to_string())
        .unwrap_or_default()
}

fn error_text(out: &Output, fallback: &str) -> String {
    let text = if out.stderr.trim().is_empty() { out.stdout.trim() } else { out.stderr.trim() };
    if text.is_empty() { fallback.to_string() } else { text.lines().last().unwrap_or(fallback).to_string() }
}

/// `--filters <json>` from the plugin: the panel's own chips, normalised
/// here. A malformed list narrows nothing rather than failing the snapshot.
fn filter_arg(rest: &[&str]) -> Vec<FilterOut> {
    let Some(at) = rest.iter().position(|a| *a == "--filters") else {
        return Vec::new();
    };
    match rest.get(at + 1) {
        Some(json) => parse_filters(json),
        None => Vec::new(),
    }
}

fn snapshot(include_waiting: bool, filters: &[FilterOut]) -> Result<Value> {
    if !task_available() {
        return Ok(unavailable("task is not installed"));
    }
    let filter = if include_waiting { "(status:pending or status:waiting)" } else { "status:pending" };
    let out = run_task(&[filter, "export"], TIMEOUT)?;
    if out.status != Some(0) {
        return Ok(json!({ "ok": false, "available": true, "error": error_text(&out, "task export failed") }));
    }
    if out.stdout_truncated {
        return Ok(json!({ "ok": false, "available": true, "error": "task export is larger than 4 MiB; narrow it down in the terminal first" }));
    }
    // One odd task (an old export format, a UDA of an unexpected type) is
    // skipped and counted rather than taking the whole list down.
    let items: Vec<Value> = if out.stdout.trim().is_empty() {
        Vec::new()
    } else {
        serde_json::from_str(&out.stdout).context("task export was not JSON")?
    };
    let mut skipped = 0usize;
    let raw: Vec<RawTask> = items
        .into_iter()
        .filter_map(|v| match serde_json::from_value::<RawTask>(v) {
            Ok(t) => Some(t),
            Err(_) => {
                skipped += 1;
                None
            }
        })
        .collect();
    // Waiting tasks are counted even when not listed, so ask for them too.
    let waiting_count = if include_waiting {
        None
    } else {
        run_task(&["status:waiting", "count"], TIMEOUT)
            .ok()
            .and_then(|o| o.stdout.trim().parse::<usize>().ok())
    };
    let mut snap = build_snapshot_filtered(&raw, &Local::now(), include_waiting, &task_version(), filters);
    if let Some(w) = waiting_count {
        snap.counts.waiting = w;
    }
    let mut value = serde_json::to_value(snap)?;
    if skipped > 0 {
        value["skipped"] = json!(skipped);
    }
    Ok(value)
}

fn action(args: &[&str], timeout: Duration, what: &str) -> Result<Value> {
    let out = run_task(args, timeout)?;
    if out.status == Some(0) {
        Ok(json!({ "ok": true, "action": what, "output": out.stdout.trim() }))
    } else {
        Ok(json!({ "ok": false, "action": what, "error": error_text(&out, &format!("{what} failed")) }))
    }
}

fn sync_configured() -> bool {
    SYNC_SETTINGS.iter().any(|key| {
        run_task(&["_get", key], Duration::from_secs(3))
            .map(|o| o.status == Some(0) && !o.stdout.trim().is_empty())
            .unwrap_or(false)
    })
}

fn dispatch(argv: &[String]) -> Result<Value> {
    let cmd = argv.first().map(String::as_str).unwrap_or("");
    let rest: Vec<&str> = argv.iter().skip(1).map(String::as_str).collect();
    match cmd {
        "snapshot" => snapshot(rest.iter().any(|a| *a == "--waiting"), &filter_arg(&rest)),
        "version" => Ok(json!({ "ok": true, "taskbridge": env!("CARGO_PKG_VERSION"), "task": task_version() })),
        "add" => {
            if rest.is_empty() {
                return Err(anyhow!("add needs a description"));
            }
            if let Some(bad) = rest.iter().find(|w| !is_allowed_add_word(w)) {
                return Err(anyhow!("refused word in add: {bad}"));
            }
            let mut args = vec!["add"];
            args.extend(rest.iter().copied());
            action(&args, TIMEOUT, "add")
        }
        "done" => {
            let uuid = rest.first().copied().unwrap_or("");
            if !is_uuid(uuid) {
                return Err(anyhow!("done needs a full uuid"));
            }
            action(&[uuid, "done"], TIMEOUT, "done")
        }
        "modify" => {
            let uuid = rest.first().copied().unwrap_or("");
            if !is_uuid(uuid) {
                return Err(anyhow!("modify needs a full uuid"));
            }
            let changes = &rest[1..];
            if changes.is_empty() {
                return Err(anyhow!("modify needs at least one change"));
            }
            if let Some(bad) = changes.iter().find(|c| !is_allowed_modification(c)) {
                return Err(anyhow!("refused modification: {bad}"));
            }
            let mut args = vec![uuid, "modify"];
            args.extend(changes.iter().copied());
            action(&args, TIMEOUT, "modify")
        }
        "undo" => action(&["undo"], TIMEOUT, "undo"),
        "sync" => {
            if !sync_configured() {
                return Ok(json!({ "ok": true, "action": "sync", "skipped": true, "reason": "no sync server configured" }));
            }
            action(&["sync"], SYNC_TIMEOUT, "sync")
        }
        "" | "-h" | "--help" | "help" => Ok(json!({ "ok": true, "usage": "omarchy-taskbridge snapshot [--waiting] [--filters <json>] | add <words…> | done <uuid> | modify <uuid> <changes…> | undo | sync | version" })),
        other => Err(anyhow!("unknown command: {other}")),
    }
}

fn main() {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let (value, code) = match dispatch(&argv) {
        Ok(v) => {
            let ok = v.get("ok").and_then(Value::as_bool).unwrap_or(false);
            (v, if ok { 0 } else { 1 })
        }
        Err(e) => (json!({ "ok": false, "error": e.to_string() }), 1),
    };
    println!("{}", value);
    std::process::exit(code);
}
