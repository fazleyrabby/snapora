//! Platform-neutral Snapora core.
//!
//! Nothing in this crate may depend on macOS (or any other OS) APIs. Platform
//! layers call into it through `snapora-ffi`.

pub mod error;
pub mod geometry;
pub mod naming;

pub use error::CoreError;

/// Version of the core library, shown in the app's About menu.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");
