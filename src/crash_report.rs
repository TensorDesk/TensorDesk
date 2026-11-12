// `PanicHookInfo` is only available since Rust 1.81, while the crate still
// declares 1.75 as its minimum supported version.
#[allow(deprecated)]
use std::{panic::PanicInfo, sync::Once, time::Duration};

use base::config::keys;
use hbb_common::{
    config::Config,
    log,
};

const DEFAULT_API_BASE: &str = "https://api.tensordesk.org";
const REQUEST_TIMEOUT: Duration = Duration::from_secs(3);
const MAX_MESSAGE_CHARS: usize = 4000;
const MAX_BACKTRACE_CHARS: usize = 16000;

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
        "device_id": Config::get_id(),
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

fn truncate(value: &str, max_chars: usize) -> String {
    if value.chars().count() <= max_chars {
        return value.to_owned();
    }
    value.chars().take(max_chars).collect()
}
