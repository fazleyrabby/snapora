//! Coordinate transforms between screen points and image pixels.
//!
//! Conventions:
//! - **Global points**: Core Graphics / ScreenCaptureKit space. Origin at the
//!   top-left of the primary display, y grows downward, units are points.
//!   Displays left of or above the primary display have negative origins.
//! - **AppKit points**: origin at the bottom-left of the primary display,
//!   y grows upward. Convert with [`appkit_to_global`].
//! - **Pixels**: display-local, origin top-left, integer units of the
//!   captured image (points × scale).

use crate::CoreError;

/// Snap values within this distance of an integer to that integer, so that
/// e.g. `0.1 * 3.0` does not round outward to an extra pixel.
const SNAP_EPSILON: f64 = 1e-6;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Rect {
    pub const fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self { x, y, width, height }
    }

    pub fn max_x(&self) -> f64 {
        self.x + self.width
    }

    pub fn max_y(&self) -> f64 {
        self.y + self.height
    }

    fn validate(&self) -> Result<(), CoreError> {
        let finite = [self.x, self.y, self.width, self.height]
            .iter()
            .all(|v| v.is_finite());
        if !finite || self.width < 0.0 || self.height < 0.0 {
            return Err(CoreError::InvalidRect);
        }
        Ok(())
    }

    /// Normalizes a rect drawn by dragging in any direction (negative size).
    pub fn standardized(&self) -> Self {
        let (x, width) = if self.width < 0.0 {
            (self.x + self.width, -self.width)
        } else {
            (self.x, self.width)
        };
        let (y, height) = if self.height < 0.0 {
            (self.y + self.height, -self.height)
        } else {
            (self.y, self.height)
        };
        Self { x, y, width, height }
    }

    pub fn intersection(&self, other: &Rect) -> Option<Rect> {
        let x0 = self.x.max(other.x);
        let y0 = self.y.max(other.y);
        let x1 = self.max_x().min(other.max_x());
        let y1 = self.max_y().min(other.max_y());
        (x1 > x0 && y1 > y0).then(|| Rect::new(x0, y0, x1 - x0, y1 - y0))
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Display {
    /// Display frame in global points.
    pub frame: Rect,
    /// Backing scale factor (pixels per point), e.g. 2.0 on Retina.
    pub scale: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PixelRect {
    pub x: u32,
    pub y: u32,
    pub width: u32,
    pub height: u32,
}

/// Converts an AppKit rect (bottom-left origin) to global points (top-left
/// origin). `primary_height` is the primary display's height in points.
pub fn appkit_to_global(rect: Rect, primary_height: f64) -> Rect {
    Rect::new(rect.x, primary_height - rect.max_y(), rect.width, rect.height)
}

/// Converts a selection in global points to a pixel rect within `display`'s
/// captured image. The selection is clipped to the display and rounded
/// outward so no selected content is lost.
pub fn selection_to_pixels(display: &Display, selection: Rect) -> Result<PixelRect, CoreError> {
    if !(display.scale.is_finite() && display.scale > 0.0) {
        return Err(CoreError::InvalidScale);
    }
    display.frame.validate()?;
    let selection = selection.standardized();
    selection.validate()?;
    if selection.width == 0.0 || selection.height == 0.0 {
        return Err(CoreError::EmptySelection);
    }

    let clipped = selection
        .intersection(&display.frame)
        .ok_or(CoreError::OutsideDisplay)?;

    let s = display.scale;
    let max_w = snap_ceil(display.frame.width * s);
    let max_h = snap_ceil(display.frame.height * s);

    let local_x = clipped.x - display.frame.x;
    let local_y = clipped.y - display.frame.y;
    let x0 = snap_floor(local_x * s).clamp(0.0, max_w);
    let y0 = snap_floor(local_y * s).clamp(0.0, max_h);
    let x1 = snap_ceil((local_x + clipped.width) * s).clamp(0.0, max_w);
    let y1 = snap_ceil((local_y + clipped.height) * s).clamp(0.0, max_h);

    if x1 <= x0 || y1 <= y0 {
        return Err(CoreError::EmptySelection);
    }
    Ok(PixelRect {
        x: x0 as u32,
        y: y0 as u32,
        width: (x1 - x0) as u32,
        height: (y1 - y0) as u32,
    })
}

/// Pixel dimensions of a full-display capture.
pub fn display_pixel_size(display: &Display) -> Result<PixelRect, CoreError> {
    selection_to_pixels(display, display.frame)
}

fn snap(v: f64) -> f64 {
    let r = v.round();
    if (v - r).abs() < SNAP_EPSILON { r } else { v }
}

fn snap_floor(v: f64) -> f64 {
    snap(v).floor()
}

fn snap_ceil(v: f64) -> f64 {
    snap(v).ceil()
}

#[cfg(test)]
mod tests {
    use super::*;

    const RETINA: Display = Display {
        frame: Rect::new(0.0, 0.0, 1512.0, 982.0),
        scale: 2.0,
    };

    #[test]
    fn full_retina_display() {
        let px = display_pixel_size(&RETINA).unwrap();
        assert_eq!(px, PixelRect { x: 0, y: 0, width: 3024, height: 1964 });
    }

    #[test]
    fn region_scales_by_backing_factor() {
        let px = selection_to_pixels(&RETINA, Rect::new(10.0, 20.0, 100.0, 50.0)).unwrap();
        assert_eq!(px, PixelRect { x: 20, y: 40, width: 200, height: 100 });
    }

    #[test]
    fn fractional_points_round_outward() {
        let px = selection_to_pixels(&RETINA, Rect::new(10.25, 0.0, 10.5, 1.0)).unwrap();
        // 20.5..41.5 -> 20..42
        assert_eq!(px, PixelRect { x: 20, y: 0, width: 22, height: 2 });
    }

    #[test]
    fn float_noise_does_not_add_pixels() {
        let d = Display { frame: Rect::new(0.0, 0.0, 100.0, 100.0), scale: 3.0 };
        let px = selection_to_pixels(&d, Rect::new(0.1, 0.1, 0.2, 0.2)).unwrap();
        assert_eq!(px, PixelRect { x: 0, y: 0, width: 1, height: 1 });
    }

    #[test]
    fn display_left_of_primary_has_negative_origin() {
        let left = Display { frame: Rect::new(-1920.0, 0.0, 1920.0, 1080.0), scale: 1.0 };
        let px = selection_to_pixels(&left, Rect::new(-100.0, 10.0, 50.0, 50.0)).unwrap();
        assert_eq!(px, PixelRect { x: 1820, y: 10, width: 50, height: 50 });
    }

    #[test]
    fn display_above_primary() {
        let above = Display { frame: Rect::new(0.0, -1440.0, 2560.0, 1440.0), scale: 2.0 };
        let px = selection_to_pixels(&above, Rect::new(0.0, -10.0, 10.0, 10.0)).unwrap();
        assert_eq!(px, PixelRect { x: 0, y: 2860, width: 20, height: 20 });
    }

    #[test]
    fn selection_spanning_displays_is_clipped() {
        let px = selection_to_pixels(&RETINA, Rect::new(1500.0, 900.0, 100.0, 100.0)).unwrap();
        assert_eq!(px, PixelRect { x: 3000, y: 1800, width: 24, height: 164 });
    }

    #[test]
    fn reversed_drag_is_standardized() {
        let px = selection_to_pixels(&RETINA, Rect::new(110.0, 70.0, -100.0, -50.0)).unwrap();
        assert_eq!(px, PixelRect { x: 20, y: 40, width: 200, height: 100 });
    }

    #[test]
    fn errors() {
        assert_eq!(
            selection_to_pixels(&RETINA, Rect::new(5000.0, 0.0, 10.0, 10.0)),
            Err(CoreError::OutsideDisplay)
        );
        assert_eq!(
            selection_to_pixels(&RETINA, Rect::new(0.0, 0.0, 0.0, 10.0)),
            Err(CoreError::EmptySelection)
        );
        assert_eq!(
            selection_to_pixels(&RETINA, Rect::new(f64::NAN, 0.0, 1.0, 1.0)),
            Err(CoreError::InvalidRect)
        );
        let bad = Display { scale: 0.0, ..RETINA };
        assert_eq!(display_pixel_size(&bad), Err(CoreError::InvalidScale));
    }

    #[test]
    fn appkit_flip() {
        // 100pt-tall rect touching the top of a 982pt primary display.
        let g = appkit_to_global(Rect::new(0.0, 882.0, 50.0, 100.0), 982.0);
        assert_eq!(g, Rect::new(0.0, 0.0, 50.0, 100.0));
        // Display below the primary: AppKit y is negative, global y > height.
        let g = appkit_to_global(Rect::new(0.0, -1080.0, 10.0, 10.0), 982.0);
        assert_eq!(g, Rect::new(0.0, 2052.0, 10.0, 10.0));
    }
}
