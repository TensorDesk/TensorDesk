pub mod keys;

use hbb_common::config::{Config, HARD_SETTINGS};

/// The installer default lives in `HARD_SETTINGS` (top-level `conn-type` in
/// `custom.txt`); a non-empty user option overrides it so the role can be
/// changed from Settings without repackaging.
fn resolve_conn_type(user: &str, hard: &str) -> String {
    if user.is_empty() {
        hard.to_owned()
    } else {
        user.to_owned()
    }
}

pub fn conn_type() -> String {
    let user = Config::get_option("conn-type");
    let hard = HARD_SETTINGS
        .read()
        .unwrap()
        .get("conn-type")
        .cloned()
        .unwrap_or_default();
    resolve_conn_type(&user, &hard)
}

#[inline]
pub fn is_incoming_only() -> bool {
    conn_type() == "incoming"
}

#[inline]
pub fn is_outgoing_only() -> bool {
    conn_type() == "outgoing"
}

/// Managed builds hide raw server settings; activation is the only supported
/// way for a device to learn its servers.
pub fn is_managed_build() -> bool {
    Config::get_builtin_option("hide-server-settings") == "Y"
}

/// A device counts as activated once it carries a tenant credential or any
/// rendezvous server config (user option or `custom.txt` default).
pub fn is_activated() -> bool {
    !Config::get_option("tenant-id").is_empty()
        || !Config::get_option("custom-rendezvous-server").is_empty()
        || !Config::get_option("rendezvous-servers").is_empty()
}

/// A managed build without activation has no legitimate server to talk to and
/// must not register against the compiled-in fallback.
#[inline]
pub fn activation_required() -> bool {
    is_managed_build() && !is_activated()
}

#[cfg(test)]
mod tests {
    use super::resolve_conn_type;

    #[test]
    fn empty_user_falls_back_to_hard_setting() {
        assert_eq!(resolve_conn_type("", "incoming"), "incoming");
        assert_eq!(resolve_conn_type("", "outgoing"), "outgoing");
    }

    #[test]
    fn user_option_overrides_hard_setting() {
        assert_eq!(resolve_conn_type("both", "incoming"), "both");
        assert_eq!(resolve_conn_type("outgoing", "incoming"), "outgoing");
    }

    #[test]
    fn both_empty_means_bidirectional() {
        assert_eq!(resolve_conn_type("", ""), "");
    }
}
