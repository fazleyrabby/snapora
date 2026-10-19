//! Recording state machine and pause-aware timeline.
//!
//! Capture frameworks stamp samples with a monotonic host clock. While a
//! recording is paused, samples are dropped and the paused duration is
//! subtracted from later samples, so the output file has no gap. Output
//! timestamps start at zero at the first accepted sample.
//!
//! All times are nanoseconds on the same monotonic clock.

use thiserror::Error;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecordingState {
    Idle,
    Recording,
    Paused,
    Stopped,
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
#[error("cannot {action} while {state:?}")]
pub struct InvalidTransition {
    pub action: &'static str,
    pub state: RecordingState,
}

#[derive(Debug, Clone)]
pub struct Timeline {
    state: RecordingState,
    /// Host time of the first accepted sample (output time zero).
    origin: Option<i64>,
    pause_started: Option<i64>,
    paused_total: i64,
    last_output: Option<i64>,
}

impl Default for Timeline {
    fn default() -> Self {
        Self::new()
    }
}

impl Timeline {
    pub fn new() -> Self {
        Self {
            state: RecordingState::Idle,
            origin: None,
            pause_started: None,
            paused_total: 0,
            last_output: None,
        }
    }

    pub fn state(&self) -> RecordingState {
        self.state
    }

    pub fn paused_total(&self) -> i64 {
        self.paused_total
    }

    /// Output duration so far (last accepted sample time), in nanoseconds.
    pub fn duration(&self) -> i64 {
        self.last_output.unwrap_or(0)
    }

    pub fn start(&mut self) -> Result<(), InvalidTransition> {
        self.expect(RecordingState::Idle, "start")?;
        self.state = RecordingState::Recording;
        Ok(())
    }

    pub fn pause(&mut self, now: i64) -> Result<(), InvalidTransition> {
        self.expect(RecordingState::Recording, "pause")?;
        self.state = RecordingState::Paused;
        self.pause_started = Some(now);
        Ok(())
    }

    pub fn resume(&mut self, now: i64) -> Result<(), InvalidTransition> {
        self.expect(RecordingState::Paused, "resume")?;
        if let Some(started) = self.pause_started.take() {
            // Pauses before the first sample don't shift anything: the origin
            // is set by the first sample after resuming.
            if self.origin.is_some() {
                self.paused_total += (now - started).max(0);
            }
        }
        self.state = RecordingState::Recording;
        Ok(())
    }

    pub fn stop(&mut self) -> Result<(), InvalidTransition> {
        match self.state {
            RecordingState::Recording | RecordingState::Paused => {
                self.state = RecordingState::Stopped;
                Ok(())
            }
            state => Err(InvalidTransition { action: "stop", state }),
        }
    }

    /// Maps a sample's host time to an output time, or `None` if the sample
    /// must be dropped (not recording, before the origin, or captured during
    /// a pause and delivered late).
    pub fn map(&mut self, pts: i64) -> Option<i64> {
        if self.state != RecordingState::Recording {
            return None;
        }
        let origin = *self.origin.get_or_insert(pts);
        let out = pts - origin - self.paused_total;
        if out < 0 {
            return None;
        }
        self.last_output = Some(self.last_output.map_or(out, |l| l.max(out)));
        Some(out)
    }

    fn expect(&self, state: RecordingState, action: &'static str) -> Result<(), InvalidTransition> {
        if self.state == state {
            Ok(())
        } else {
            Err(InvalidTransition { action, state: self.state })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const S: i64 = 1_000_000_000;

    #[test]
    fn first_sample_is_zero() {
        let mut t = Timeline::new();
        t.start().unwrap();
        assert_eq!(t.map(100 * S), Some(0));
        assert_eq!(t.map(101 * S), Some(S));
        assert_eq!(t.duration(), S);
    }

    #[test]
    fn drops_samples_when_not_recording() {
        let mut t = Timeline::new();
        assert_eq!(t.map(5), None);
        t.start().unwrap();
        t.map(10 * S);
        t.pause(11 * S).unwrap();
        assert_eq!(t.map(12 * S), None);
        t.resume(15 * S).unwrap();
        t.stop().unwrap();
        assert_eq!(t.map(16 * S), None);
    }

    #[test]
    fn pause_gap_is_removed() {
        let mut t = Timeline::new();
        t.start().unwrap();
        t.map(10 * S);
        t.pause(12 * S).unwrap();
        t.resume(20 * S).unwrap();
        assert_eq!(t.map(20 * S), Some(2 * S));
        assert_eq!(t.map(21 * S), Some(3 * S));
        assert_eq!(t.paused_total(), 8 * S);
    }

    #[test]
    fn multiple_pauses_accumulate() {
        let mut t = Timeline::new();
        t.start().unwrap();
        t.map(0);
        t.pause(S).unwrap();
        t.resume(2 * S).unwrap();
        t.pause(3 * S).unwrap();
        t.resume(5 * S).unwrap();
        assert_eq!(t.map(6 * S), Some(3 * S));
    }

    #[test]
    fn late_sample_from_before_resume_is_dropped() {
        let mut t = Timeline::new();
        t.start().unwrap();
        t.map(10 * S);
        t.pause(11 * S).unwrap();
        t.resume(20 * S).unwrap();
        // Captured at 10.5s, delivered after resume: maps before origin, dropped.
        assert_eq!(t.map(10 * S + S / 2), None);
    }

    #[test]
    fn pause_before_first_sample_does_not_shift() {
        let mut t = Timeline::new();
        t.start().unwrap();
        t.pause(S).unwrap();
        t.resume(5 * S).unwrap();
        assert_eq!(t.map(6 * S), Some(0));
        assert_eq!(t.paused_total(), 0);
    }

    #[test]
    fn invalid_transitions() {
        let mut t = Timeline::new();
        assert!(t.pause(0).is_err());
        assert!(t.resume(0).is_err());
        assert!(t.stop().is_err());
        t.start().unwrap();
        assert!(t.start().is_err());
        assert!(t.resume(0).is_err());
        t.pause(0).unwrap();
        assert!(t.pause(0).is_err());
        t.stop().unwrap();
        assert_eq!(t.state(), RecordingState::Stopped);
        assert!(t.start().is_err());
    }
}
