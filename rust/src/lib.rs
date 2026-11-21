//! Client side of Runner remote control for the mobile app.
//!
//! The Flutter UI will call into this crate through flutter_rust_bridge. For now it
//! exposes protocol constants so CI can prove `runner-core` builds for Android and iOS.

use runner_core::companion::{self, channel};

/// Companion protocol version this client speaks.
pub fn companion_version() -> u32 {
    companion::VERSION
}

/// Largest channel frame the relay carries.
pub fn max_frame() -> usize {
    channel::MAX_FRAME
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exposes_protocol_constants() {
        assert_eq!(companion_version(), 1);
        assert_eq!(max_frame(), 65_536);
    }
}
