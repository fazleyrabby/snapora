//! UniFFI surface exposed to the Swift app. Keep this layer thin: convert
//! types, call `snapora-core`, convert errors. No logic lives here.

use std::sync::Once;

mod editor;
mod history;
mod recording;

pub use editor::*;
pub use history::*;
pub use recording::*;

use snapora_core::{geometry, naming};

uniffi::setup_scaffolding!();

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum SnaporaError {
    #[error("{message}")]
    Geometry { message: String },
    #[error("{message}")]
    Editor { message: String },
    #[error("{message}")]
    History { message: String },
    #[error("{message}")]
    Recording { message: String },
}

impl From<snapora_core::CoreError> for SnaporaError {
    fn from(e: snapora_core::CoreError) -> Self {
        SnaporaError::Geometry { message: e.to_string() }
    }
}

#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct DisplayGeometry {
    /// Display frame in global points (top-left origin).
    pub frame: Rect,
    pub scale: f64,
}

#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct PixelRect {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}

impl From<Rect> for geometry::Rect {
    fn from(r: Rect) -> Self {
        geometry::Rect::new(r.x, r.y, r.width, r.height)
    }
}

impl From<geometry::Rect> for Rect {
    fn from(r: geometry::Rect) -> Self {
        Rect { x: r.x, y: r.y, width: r.width, height: r.height }
    }
}

impl From<DisplayGeometry> for geometry::Display {
    fn from(d: DisplayGeometry) -> Self {
        geometry::Display { frame: d.frame.into(), scale: d.scale }
    }
}

impl From<geometry::PixelRect> for PixelRect {
    fn from(p: geometry::PixelRect) -> Self {
        PixelRect { x: p.x, y: p.y, width: p.width, height: p.height }
    }
}

static LOGGING: Once = Once::new();

/// Initializes Rust-side logging to stderr. Safe to call more than once.
/// Filter with `SNAPORA_LOG` (e.g. `SNAPORA_LOG=debug`).
#[uniffi::export]
pub fn init_logging() {
    LOGGING.call_once(|| {
        let filter = tracing_subscriber::EnvFilter::try_from_env("SNAPORA_LOG")
            .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"));
        let _ = tracing_subscriber::fmt()
            .with_env_filter(filter)
            .with_writer(std::io::stderr)
            .try_init();
        tracing::info!(version = snapora_core::VERSION, "snapora core initialized");
    });
}

#[uniffi::export]
pub fn core_version() -> String {
    snapora_core::VERSION.to_owned()
}

#[uniffi::export]
pub fn default_file_name_template() -> String {
    naming::DEFAULT_TEMPLATE.to_owned()
}

/// File name for a capture taken now, e.g. `Snapora 2026-03-07 at 09.05.02.png`.
#[uniffi::export]
pub fn capture_file_name(template: String, extension: String) -> String {
    naming::file_name_now(&template, &extension)
}

#[uniffi::export]
pub fn appkit_to_global(rect: Rect, primary_height: f64) -> Rect {
    geometry::appkit_to_global(rect.into(), primary_height).into()
}

#[uniffi::export]
pub fn selection_to_pixels(
    display: DisplayGeometry,
    selection: Rect,
) -> Result<PixelRect, SnaporaError> {
    Ok(geometry::selection_to_pixels(&display.into(), selection.into())?.into())
}

#[uniffi::export]
pub fn display_pixel_size(display: DisplayGeometry) -> Result<PixelRect, SnaporaError> {
    Ok(geometry::display_pixel_size(&display.into())?.into())
}
