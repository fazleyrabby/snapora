//! Pause-aware recording timeline (see `snapora_core::recording`).

use std::sync::Mutex;

use snapora_core::recording::{self, Timeline};

use crate::SnaporaError;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum RecordingState {
    Idle,
    Recording,
    Paused,
    Stopped,
}

impl From<recording::RecordingState> for RecordingState {
    fn from(s: recording::RecordingState) -> Self {
        match s {
            recording::RecordingState::Idle => Self::Idle,
            recording::RecordingState::Recording => Self::Recording,
            recording::RecordingState::Paused => Self::Paused,
            recording::RecordingState::Stopped => Self::Stopped,
        }
    }
}

impl From<recording::InvalidTransition> for SnaporaError {
    fn from(e: recording::InvalidTransition) -> Self {
        SnaporaError::Recording { message: e.to_string() }
    }
}

/// Times are nanoseconds on the host monotonic clock.
#[derive(uniffi::Object)]
pub struct RecordingTimeline {
    inner: Mutex<Timeline>,
}

impl RecordingTimeline {
    fn lock(&self) -> std::sync::MutexGuard<'_, Timeline> {
        self.inner.lock().unwrap_or_else(|p| p.into_inner())
    }
}

#[uniffi::export]
impl RecordingTimeline {
    #[uniffi::constructor]
    pub fn new() -> Self {
        Self { inner: Mutex::new(Timeline::new()) }
    }

    pub fn state(&self) -> RecordingState {
        self.lock().state().into()
    }

    pub fn start(&self) -> Result<(), SnaporaError> {
        Ok(self.lock().start()?)
    }

    pub fn pause(&self, now_ns: i64) -> Result<(), SnaporaError> {
        Ok(self.lock().pause(now_ns)?)
    }

    pub fn resume(&self, now_ns: i64) -> Result<(), SnaporaError> {
        Ok(self.lock().resume(now_ns)?)
    }

    pub fn stop(&self, now_ns: i64) -> Result<(), SnaporaError> {
        Ok(self.lock().stop(now_ns)?)
    }

    /// Elapsed output time at host time `now_ns` (excludes pauses).
    pub fn output_time_ns(&self, now_ns: i64) -> i64 {
        self.lock().output_time(now_ns)
    }

    /// Output time for a sample, or `None` to drop it.
    pub fn map(&self, pts_ns: i64) -> Option<i64> {
        self.lock().map(pts_ns)
    }

    pub fn duration_ns(&self) -> i64 {
        self.lock().duration()
    }
}

impl Default for RecordingTimeline {
    fn default() -> Self {
        Self::new()
    }
}
