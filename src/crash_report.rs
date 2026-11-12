// `PanicHookInfo` is only available since Rust 1.81, while the crate still
// declares 1.75 as its minimum supported version.
#[allow(deprecated)]
use std::{
    collections::{hash_map::DefaultHasher, VecDeque},
    hash::{Hash, Hasher},
    panic::PanicInfo,
    sync::{Mutex, Once, OnceLock},
    time::{Duration, Instant},
};

use base::config::keys;
use hbb_common::{
    config::Config,
    log,
};

const DEFAULT_API_BASE: &str = "https://api.tensordesk.org";
const REQUEST_TIMEOUT: Duration = Duration::from_secs(3);
const MAX_MESSAGE_CHARS: usize = 4000;
const MAX_BACKTRACE_CHARS: usize = 16000;
const MAX_LOG_TAIL_BYTES: usize = 8 * 1024;
const REPEAT_WINDOW: Duration = Duration::from_secs(60);
const RATE_WINDOW: Duration = Duration::from_secs(600);
const RATE_LIMIT: usize = 10;

#[derive(Default)]
struct Throttle {
    last: Option<(u64, Instant)>,
    sent: VecDeque<Instant>,
}

fn throttle() -> &'static Mutex<Throttle> {
    static THROTTLE: OnceLock<Mutex<Throttle>> = OnceLock::new();
    THROTTLE.get_or_init(|| Mutex::new(Throttle::default()))
}

/// A crash loop can fire an app-level error thousands of times and a panic loop
/// restarts the process, so the client also caps what one process sends.
fn allowed(kind: &str, message: &str) -> bool {
    let now = Instant::now();
    let mut hasher = DefaultHasher::new();
    kind.hash(&mut hasher);
    message.hash(&mut hasher);
    let fingerprint = hasher.finish();
    let Ok(mut throttle) = throttle().lock() else {
        return true;
    };
    if let Some((last, at)) = throttle.last {
        if last == fingerprint && now.saturating_duration_since(at) < REPEAT_WINDOW {
            return false;
        }
    }
    while throttle
        .sent
        .front()
        .map(|at| now.saturating_duration_since(*at) >= RATE_WINDOW)
        .unwrap_or(false)
    {
        throttle.sent.pop_front();
    }
    if throttle.sent.len() >= RATE_LIMIT {
        return false;
    }
    throttle.last = Some((fingerprint, now));
    throttle.sent.push_back(now);
    true
}

/// Reports panics to the control plane. The release profile aborts on panic,
/// so the request is sent synchronously before the hook returns; the previous
/// hook runs first so local logging is unchanged.
pub fn install() {
    static INSTALLED: Once = Once::new();
    INSTALLED.call_once(|| {
        let previous = std::panic::take_hook();
        std::panic::set_hook(Box::new(move |info| {
            previous(info);
            let message = panic_message(info);
            if !allowed("panic", &message) {
                log::trace!("crash report skipped: duplicate or rate limited");
                return;
            }
            let backtrace = std::backtrace::Backtrace::force_capture().to_string();
            if let Err(err) = send("panic", &message, Some(&backtrace)) {
                log::warn!("crash report failed: {err}");
            }
        }));
    });
}

/// Reports an app-level error (currently Flutter exceptions) without blocking
/// the caller; unlike a panic the app keeps running.
pub fn report(kind: &str, message: &str, backtrace: &str) {
    let kind = kind.to_owned();
    let message = truncate(message, MAX_MESSAGE_CHARS);
    if !allowed(&kind, &message) {
        log::trace!("crash report skipped: duplicate or rate limited");
        return;
    }
    let backtrace = truncate(backtrace, MAX_BACKTRACE_CHARS);
    let spawned = std::thread::Builder::new()
        .name("crash-report".to_owned())
        .spawn(move || {
            if let Err(err) = send(&kind, &message, Some(&backtrace)) {
                log::warn!("crash report failed: {err}");
            }
        });
    if let Err(err) = spawned {
        log::warn!("failed to spawn crash report thread: {err}");
    }
}

#[allow(deprecated)]
fn panic_message(info: &PanicInfo) -> String {
    let payload = if let Some(value) = info.payload().downcast_ref::<&str>() {
        (*value).to_owned()
    } else if let Some(value) = info.payload().downcast_ref::<String>() {
        value.clone()
    } else {
        "unknown panic payload".to_owned()
    };
    let location = info
        .location()
        .map(|location| format!("{}:{}", location.file(), location.line()))
        .unwrap_or_else(|| "unknown location".to_owned());
    let thread = std::thread::current();
    let thread = thread.name().unwrap_or("unnamed");
    truncate(
        &format!("{payload} (thread {thread}, {location})"),
        MAX_MESSAGE_CHARS,
    )
}

fn send(kind: &str, message: &str, backtrace: Option<&str>) -> Result<(), String> {
    let proof = Config::get_option(keys::OPTION_TENANT_PROOF);
    if proof.is_empty() {
        return Ok(());
    }
    let base = option_env!("TENSORDESK_API_BASE").unwrap_or(DEFAULT_API_BASE);
    let url = format!("{}/api/client/crash", base.trim_end_matches('/'));
    let body = serde_json::json!({
        "kind": kind,
        "message": message,
        "backtrace": backtrace,
        "app_version": crate::VERSION,
        "platform": std::env::consts::OS,
        "os_version": os_version(),
        "arch": std::env::consts::ARCH,
        "device_id": Config::get_id(),
        "log_tail": log_tail(),
    });
    let client = reqwest::blocking::Client::builder()
        .timeout(REQUEST_TIMEOUT)
        .build()
        .map_err(|err| err.to_string())?;
    let response = client
        .post(&url)
        .bearer_auth(&proof)
        .json(&body)
        .send()
        .map_err(|err| err.to_string())?;
    if !response.status().is_success() {
        return Err(format!("api returned {}", response.status()));
    }
    Ok(())
}

fn os_version() -> String {
    use hbb_common::sysinfo::System;
    let mut system = System::new();
    let mut parts = Vec::new();
    let distro = system.distribution_id();
    if !distro.is_empty() {
        parts.push(distro);
    }
    if let Some(version) = system.long_os_version().filter(|value| !value.is_empty()) {
        parts.push(version);
    }
    if let Some(kernel) = system.kernel_version().filter(|value| !value.is_empty()) {
        parts.push(format!("kernel {kernel}"));
    }
    parts.join(" ")
}

/// The newest log file holds the lines leading up to a crash, which is often
/// the only trace of what the session was doing.
fn log_tail() -> Option<String> {
    use std::{
        io::{Read, Seek, SeekFrom},
        time::SystemTime,
    };
    let dir = Config::log_path();
    let mut newest: Option<(SystemTime, std::path::PathBuf)> = None;
    for entry in std::fs::read_dir(&dir).ok()?.flatten() {
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        let Ok(modified) = entry.metadata().and_then(|meta| meta.modified()) else {
            continue;
        };
        if newest
            .as_ref()
            .map(|(time, _)| modified > *time)
            .unwrap_or(true)
        {
            newest = Some((modified, path));
        }
    }
    let (_, path) = newest?;
    let mut file = std::fs::File::open(path).ok()?;
    let len = file.metadata().ok()?.len();
    file.seek(SeekFrom::Start(
        len.saturating_sub(MAX_LOG_TAIL_BYTES as u64),
    ))
    .ok()?;
    let mut tail = Vec::with_capacity(MAX_LOG_TAIL_BYTES);
    file.take(MAX_LOG_TAIL_BYTES as u64)
        .read_to_end(&mut tail)
        .ok()?;
    Some(String::from_utf8_lossy(&tail).into_owned())
}

fn truncate(value: &str, max_chars: usize) -> String {
    if value.chars().count() <= max_chars {
        return value.to_owned();
    }
    value.chars().take(max_chars).collect()
}

#[cfg(test)]
mod tests {
    use super::{allowed, os_version};

    #[test]
    fn throttle_drops_duplicates_and_caps_the_window() {
        assert!(allowed("panic", "duplicate"));
        assert!(!allowed("panic", "duplicate"));
        for index in 0..9 {
            assert!(allowed("panic", &format!("unique {index}")));
        }
        assert!(!allowed("panic", "one more"));
    }

    #[test]
    fn os_version_is_reported() {
        assert!(!os_version().is_empty());
    }
}
