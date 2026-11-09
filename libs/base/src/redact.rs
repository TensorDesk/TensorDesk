/// Stable short tag for a server address, safe to write into logs. The design
/// hides hbbs/hbbr topology from users, so logs must not carry full addresses;
/// a tag still lets support correlate lines about the same server.
pub fn host_tag(addr: &str) -> String {
    // FNV-1a 32-bit: dependency-free and stable across builds.
    let mut h: u32 = 0x811c9dc5;
    for b in addr.as_bytes() {
        h ^= *b as u32;
        h = h.wrapping_mul(0x0100_0193);
    }
    format!("srv-{h:08x}")
}

#[cfg(test)]
mod tests {
    use super::host_tag;

    #[test]
    fn tag_is_stable_and_contains_no_address() {
        let addr = "hbbs-1.internal.example.com:21116";
        assert_eq!(host_tag(addr), host_tag(addr));
        assert!(!host_tag(addr).contains("example"));
        assert!(!host_tag(addr).contains("21116"));
    }

    #[test]
    fn different_addresses_get_different_tags() {
        assert_ne!(host_tag("10.0.0.1:21116"), host_tag("10.0.0.2:21116"));
    }
}
