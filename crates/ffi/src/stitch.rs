//! Scrolling-capture stitcher (see `snapora_core::stitch`).

use std::sync::Mutex;

use snapora_core::stitch::{self, Frame, Stitcher};

use crate::SnaporaError;

impl From<stitch::StitchError> for SnaporaError {
    fn from(e: stitch::StitchError) -> Self {
        SnaporaError::Stitch { message: e.to_string() }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum StitchOutcome {
    Appended { rows: u32, uncertain: bool },
    NoMovement,
    NoMatch,
    SizeChanged,
    LimitReached,
}

impl From<stitch::FrameOutcome> for StitchOutcome {
    fn from(o: stitch::FrameOutcome) -> Self {
        match o {
            stitch::FrameOutcome::Appended { rows, uncertain } => {
                Self::Appended { rows: rows as u32, uncertain }
            }
            stitch::FrameOutcome::NoMovement => Self::NoMovement,
            stitch::FrameOutcome::NoMatch => Self::NoMatch,
            stitch::FrameOutcome::SizeChanged => Self::SizeChanged,
            stitch::FrameOutcome::LimitReached => Self::LimitReached,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct StitchedImage {
    pub width: u32,
    pub height: u32,
    /// Tightly packed 4-byte pixels, same channel order as the input frames.
    pub data: Vec<u8>,
    pub uncertain_joins: u32,
    pub frames_used: u32,
}

/// Frames are 4-byte-per-pixel buffers (BGRA or RGBA).
#[derive(uniffi::Object)]
pub struct ScrollStitcher {
    inner: Mutex<Option<Stitcher>>,
}

fn frame(width: u32, height: u32, bytes_per_row: u32, data: &[u8]) -> Frame<'_> {
    Frame {
        width: width as usize,
        height: height as usize,
        bytes_per_row: bytes_per_row as usize,
        data,
    }
}

fn finished() -> SnaporaError {
    SnaporaError::Stitch { message: "stitcher already finished".into() }
}

#[uniffi::export]
impl ScrollStitcher {
    #[uniffi::constructor]
    pub fn new(
        width: u32,
        height: u32,
        bytes_per_row: u32,
        data: Vec<u8>,
        max_rows: u32,
    ) -> Result<Self, SnaporaError> {
        let s = Stitcher::new(frame(width, height, bytes_per_row, &data), max_rows as usize)?;
        Ok(Self { inner: Mutex::new(Some(s)) })
    }

    pub fn push(
        &self,
        width: u32,
        height: u32,
        bytes_per_row: u32,
        data: Vec<u8>,
    ) -> Result<StitchOutcome, SnaporaError> {
        let mut guard = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        let s = guard.as_mut().ok_or_else(finished)?;
        Ok(s.push(frame(width, height, bytes_per_row, &data))?.into())
    }

    /// Current output height in pixels.
    pub fn height(&self) -> u32 {
        let guard = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        guard.as_ref().map_or(0, |s| s.height() as u32)
    }

    pub fn finish(&self) -> Result<StitchedImage, SnaporaError> {
        let mut guard = self.inner.lock().unwrap_or_else(|p| p.into_inner());
        let r = guard.take().ok_or_else(finished)?.finish();
        Ok(StitchedImage {
            width: r.width as u32,
            height: r.height as u32,
            data: r.data,
            uncertain_joins: r.uncertain_joins,
            frames_used: r.frames_used,
        })
    }
}
