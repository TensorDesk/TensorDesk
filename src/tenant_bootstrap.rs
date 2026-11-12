use base::config::keys;
use hbb_common::{
    anyhow::bail,
    config::Config,
    log,
    tokio::{
        self,
        time::{sleep, Duration},
    },
    ResultType,
};
use serde_json::Value;

const REFRESH_INTERVAL: Duration = Duration::from_secs(6 * 3600);
const DEFAULT_API_BASE: &str = "https://api.tensordesk.org";

#[cfg(not(target_os = "ios"))]
fn restart_rendezvous() {
    crate::rendezvous_mediator::RendezvousMediator::restart();
}

#[cfg(target_os = "ios")]
fn restart_rendezvous() {}

/// Periodic control-plane bootstrap for managed builds: keeps the local
/// rendezvous/relay/key config in sync with what the tenant's pool resolves
/// to, so nodes can be rescheduled without touching clients. Failures keep
/// the cached config; a 401/403 means the device credential was revoked and
/// the client drops back to the pending-activation state.
pub fn start() {
    if !base::config::is_managed_build() {
        return;
    }
    tokio::spawn(async {
        loop {
            if let Err(err) = refresh().await {
                log::warn!("tenant bootstrap refresh failed: {err}");
            }
            sleep(REFRESH_INTERVAL).await;
        }
    });
}

async fn refresh() -> ResultType<()> {
    let proof = Config::get_option(keys::OPTION_TENANT_PROOF);
    if proof.is_empty() {
        return Ok(());
    }
    let base = option_env!("TENSORDESK_API_BASE").unwrap_or(DEFAULT_API_BASE);
    let url = format!("{}/api/client/bootstrap", base.trim_end_matches('/'));
    let client = crate::hbbs_http::create_http_client_async_with_url(&url).await;
    let response = client.get(&url).bearer_auth(&proof).send().await?;
    let status = response.status();
    if status == reqwest::StatusCode::UNAUTHORIZED || status == reqwest::StatusCode::FORBIDDEN {
        log::warn!("tenant bootstrap credential rejected ({status}), deactivating");
        deactivate();
        return Ok(());
    }
    if !status.is_success() {
        bail!("bootstrap returned {status}");
    }
    let body: Value = response.json().await?;
    if apply_config(&body) {
        restart_rendezvous();
    }
    Config::set_option(
        keys::OPTION_BOOTSTRAP_FETCHED_AT.to_owned(),
        hbb_common::chrono::Utc::now().timestamp().to_string(),
    );
    Ok(())
}

/// Writes the bootstrap fields that differ from the local config. Returns
/// true when anything changed and the rendezvous mediator should reconnect.
fn apply_config(body: &Value) -> bool {
    let fields = [
        ("host", keys::OPTION_CUSTOM_RENDEZVOUS_SERVER),
        ("relay", keys::OPTION_RELAY_SERVER),
        ("api", keys::OPTION_API_SERVER),
        ("key", keys::OPTION_KEY),
        ("tenant_id", keys::OPTION_TENANT_ID),
    ];
    let mut changed = false;
    for (field, option) in fields {
        let Some(value) = body.get(field).and_then(|value| value.as_str()) else {
            continue;
        };
        if Config::get_option(option) != value {
            Config::set_option(option.to_owned(), value.to_owned());
            changed = true;
        }
    }
    changed
}

/// The credential is dead: wipe everything it provided so
/// `activation_required()` holds and the client waits for a new activation
/// instead of talking to servers nobody assigned to it.
fn deactivate() {
    for option in [
        keys::OPTION_TENANT_ID,
        keys::OPTION_TENANT_PROOF,
        keys::OPTION_CUSTOM_RENDEZVOUS_SERVER,
        keys::OPTION_RELAY_SERVER,
        keys::OPTION_API_SERVER,
        keys::OPTION_KEY,
    ] {
        Config::set_option(option.to_owned(), String::new());
    }
    restart_rendezvous();
}
