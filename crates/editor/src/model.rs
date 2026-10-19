//! Annotation value types, bounds, and hit testing.

use serde::{Deserialize, Serialize};

/// RGBA color, components in `0.0..=1.0`.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Color {
    pub r: f32,
    pub g: f32,
    pub b: f32,
    pub a: f32,
}

impl Color {
    pub const fn new(r: f32, g: f32, b: f32, a: f32) -> Self {
        Self { r, g, b, a }
    }

    pub const RED: Color = Color::new(1.0, 0.2, 0.2, 1.0);
}

/// A point in image pixels (top-left origin).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

impl Point {
    pub const fn new(x: f64, y: f64) -> Self {
        Self { x, y }
    }

    fn translated(self, dx: f64, dy: f64) -> Self {
        Self::new(self.x + dx, self.y + dy)
    }

    fn distance(self, other: Point) -> f64 {
        (self.x - other.x).hypot(self.y - other.y)
    }
}

/// An axis-aligned rectangle in image pixels.
///
/// Serializable twin of `snapora_core::geometry::Rect`; convert with `From`.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
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

    /// Grows the rect by `d` on every side (shrinks when negative).
    pub fn inflated(&self, d: f64) -> Self {
        Self::new(self.x - d, self.y - d, self.width + 2.0 * d, self.height + 2.0 * d)
    }

    /// Whether `p` lies inside the (standardized) rect, edges inclusive.
    pub fn contains(&self, p: Point) -> bool {
        let r = self.standardized();
        p.x >= r.x && p.x <= r.max_x() && p.y >= r.y && p.y <= r.max_y()
    }

    pub fn is_finite(&self) -> bool {
        [self.x, self.y, self.width, self.height].iter().all(|v| v.is_finite())
    }

    fn translated(self, dx: f64, dy: f64) -> Self {
        Self::new(self.x + dx, self.y + dy, self.width, self.height)
    }

    fn from_points<'a>(points: impl IntoIterator<Item = &'a Point>) -> Self {
        let mut it = points.into_iter();
        let Some(first) = it.next() else {
            return Rect::new(0.0, 0.0, 0.0, 0.0);
        };
        let (mut x0, mut y0, mut x1, mut y1) = (first.x, first.y, first.x, first.y);
        for p in it {
            x0 = x0.min(p.x);
            y0 = y0.min(p.y);
            x1 = x1.max(p.x);
            y1 = y1.max(p.y);
        }
        Rect::new(x0, y0, x1 - x0, y1 - y0)
    }
}

impl From<snapora_core::geometry::Rect> for Rect {
    fn from(r: snapora_core::geometry::Rect) -> Self {
        Rect::new(r.x, r.y, r.width, r.height)
    }
}

impl From<Rect> for snapora_core::geometry::Rect {
    fn from(r: Rect) -> Self {
        snapora_core::geometry::Rect::new(r.x, r.y, r.width, r.height)
    }
}

/// Stable identifier of an annotation within a document.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
pub struct AnnotationId(pub u64);

/// Visual style shared by all annotation kinds (kinds ignore what they don't use).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Style {
    pub stroke: Color,
    pub fill: Option<Color>,
    pub line_width: f64,
    pub font_size: f64,
}

impl Default for Style {
    fn default() -> Self {
        Self { stroke: Color::RED, fill: None, line_width: 4.0, font_size: 24.0 }
    }
}

/// The geometry/payload of an annotation.
///
/// `Blur`, `Pixelate` and `Redact` are destructive: renderers must bake them
/// into exported pixels. See [`AnnotationKind::is_destructive`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum AnnotationKind {
    Arrow { start: Point, end: Point },
    Line { start: Point, end: Point },
    Rectangle { rect: Rect },
    Ellipse { rect: Rect },
    /// `origin` is the top-left of the text box.
    Text { origin: Point, text: String },
    Freehand { points: Vec<Point> },
    Counter { center: Point, number: u32 },
    Highlight { rect: Rect },
    Spotlight { rect: Rect },
    Blur { rect: Rect, radius: f64 },
    Pixelate { rect: Rect, block_size: u32 },
    Redact { rect: Rect },
}

impl AnnotationKind {
    /// True for kinds that irreversibly alter exported pixels.
    pub fn is_destructive(&self) -> bool {
        matches!(
            self,
            AnnotationKind::Blur { .. } | AnnotationKind::Pixelate { .. } | AnnotationKind::Redact { .. }
        )
    }
}

/// Arrowhead extent as a multiple of line width (used for bounds).
const ARROW_HEAD_FACTOR: f64 = 3.0;
/// Approximate average glyph advance as a fraction of font size.
const TEXT_ADVANCE: f64 = 0.6;
/// Approximate line height as a multiple of font size.
const TEXT_LINE_HEIGHT: f64 = 1.2;

/// A single drawable object.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Annotation {
    pub id: AnnotationId,
    pub kind: AnnotationKind,
    pub style: Style,
}

impl Annotation {
    pub fn new(id: AnnotationId, kind: AnnotationKind, style: Style) -> Self {
        Self { id, kind, style }
    }

    /// Radius of a counter badge, derived from font size.
    fn counter_radius(&self) -> f64 {
        self.style.font_size * 0.9
    }

    /// Estimated text box (the renderer owns exact metrics).
    fn text_rect(&self, origin: Point, text: &str) -> Rect {
        let lines = text.split('\n');
        let longest = lines.clone().map(|l| l.chars().count()).max().unwrap_or(0);
        let count = lines.count().max(1);
        Rect::new(
            origin.x,
            origin.y,
            longest as f64 * self.style.font_size * TEXT_ADVANCE,
            count as f64 * self.style.font_size * TEXT_LINE_HEIGHT,
        )
    }

    /// Axis-aligned bounding box, including half the line width for strokes.
    pub fn bounds(&self) -> Rect {
        let half = self.style.line_width.max(0.0) / 2.0;
        match &self.kind {
            AnnotationKind::Arrow { start, end } => {
                Rect::from_points([start, end]).inflated(half.max(self.style.line_width * ARROW_HEAD_FACTOR))
            }
            AnnotationKind::Line { start, end } => Rect::from_points([start, end]).inflated(half),
            AnnotationKind::Rectangle { rect } | AnnotationKind::Ellipse { rect } => {
                rect.standardized().inflated(half)
            }
            AnnotationKind::Text { origin, text } => self.text_rect(*origin, text),
            AnnotationKind::Freehand { points } => Rect::from_points(points).inflated(half),
            AnnotationKind::Counter { center, .. } => {
                let r = self.counter_radius();
                Rect::new(center.x - r, center.y - r, 2.0 * r, 2.0 * r)
            }
            AnnotationKind::Highlight { rect }
            | AnnotationKind::Spotlight { rect }
            | AnnotationKind::Blur { rect, .. }
            | AnnotationKind::Pixelate { rect, .. }
            | AnnotationKind::Redact { rect } => rect.standardized(),
        }
    }

    /// Returns a copy moved by `(dx, dy)`.
    pub fn translated(&self, dx: f64, dy: f64) -> Annotation {
        let mut out = self.clone();
        out.translate(dx, dy);
        out
    }

    pub(crate) fn translate(&mut self, dx: f64, dy: f64) {
        match &mut self.kind {
            AnnotationKind::Arrow { start, end } | AnnotationKind::Line { start, end } => {
                *start = start.translated(dx, dy);
                *end = end.translated(dx, dy);
            }
            AnnotationKind::Rectangle { rect }
            | AnnotationKind::Ellipse { rect }
            | AnnotationKind::Highlight { rect }
            | AnnotationKind::Spotlight { rect }
            | AnnotationKind::Blur { rect, .. }
            | AnnotationKind::Pixelate { rect, .. }
            | AnnotationKind::Redact { rect } => *rect = rect.translated(dx, dy),
            AnnotationKind::Text { origin, .. } => *origin = origin.translated(dx, dy),
            AnnotationKind::Freehand { points } => {
                for p in points {
                    *p = p.translated(dx, dy);
                }
            }
            AnnotationKind::Counter { center, .. } => *center = center.translated(dx, dy),
        }
    }

    /// Whether `p` hits this annotation within `tolerance` pixels.
    ///
    /// Lines, arrows and freehand strokes use distance to the polyline;
    /// region kinds, text and counters use their area; unfilled rectangles
    /// and ellipses only hit near their outline.
    pub fn hit_test(&self, p: Point, tolerance: f64) -> bool {
        let tol = tolerance.max(0.0);
        let reach = tol + self.style.line_width.max(0.0) / 2.0;
        match &self.kind {
            AnnotationKind::Arrow { start, end } | AnnotationKind::Line { start, end } => {
                dist_to_segment(p, *start, *end) <= reach
            }
            AnnotationKind::Freehand { points } => match points.as_slice() {
                [] => false,
                [only] => only.distance(p) <= reach,
                _ => points.windows(2).any(|w| dist_to_segment(p, w[0], w[1]) <= reach),
            },
            AnnotationKind::Rectangle { rect } => {
                let r = rect.standardized();
                if self.style.fill.is_some() {
                    r.inflated(reach).contains(p)
                } else {
                    r.inflated(reach).contains(p) && !r.inflated(-reach).contains_strict(p)
                }
            }
            AnnotationKind::Ellipse { rect } => {
                let r = rect.standardized();
                let (a, b) = (r.width / 2.0, r.height / 2.0);
                if a < 1e-9 || b < 1e-9 {
                    return r.inflated(reach).contains(p);
                }
                let (dx, dy) = (p.x - (r.x + a), p.y - (r.y + b));
                let f = (dx * dx / (a * a) + dy * dy / (b * b)).sqrt();
                if self.style.fill.is_some() && f <= 1.0 {
                    return true;
                }
                // First-order distance to the ellipse boundary.
                (f - 1.0).abs() * a.min(b) <= reach
            }
            AnnotationKind::Text { .. } => self.bounds().inflated(tol).contains(p),
            AnnotationKind::Counter { center, .. } => center.distance(p) <= self.counter_radius() + tol,
            AnnotationKind::Highlight { rect }
            | AnnotationKind::Spotlight { rect }
            | AnnotationKind::Blur { rect, .. }
            | AnnotationKind::Pixelate { rect, .. }
            | AnnotationKind::Redact { rect } => rect.standardized().inflated(tol).contains(p),
        }
    }
}

impl Rect {
    /// Strictly inside (edges excluded); false for degenerate rects.
    fn contains_strict(&self, p: Point) -> bool {
        self.width > 0.0 && self.height > 0.0 && p.x > self.x && p.x < self.max_x() && p.y > self.y && p.y < self.max_y()
    }
}

fn dist_to_segment(p: Point, a: Point, b: Point) -> f64 {
    let (dx, dy) = (b.x - a.x, b.y - a.y);
    let len2 = dx * dx + dy * dy;
    if len2 == 0.0 {
        return p.distance(a);
    }
    let t = (((p.x - a.x) * dx + (p.y - a.y) * dy) / len2).clamp(0.0, 1.0);
    p.distance(Point::new(a.x + t * dx, a.y + t * dy))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn style(lw: f64) -> Style {
        Style { line_width: lw, ..Style::default() }
    }

    fn ann(kind: AnnotationKind, s: Style) -> Annotation {
        Annotation::new(AnnotationId(1), kind, s)
    }

    #[test]
    fn line_bounds_include_half_width() {
        let a = ann(AnnotationKind::Line { start: Point::new(10.0, 20.0), end: Point::new(30.0, 10.0) }, style(4.0));
        assert_eq!(a.bounds(), Rect::new(8.0, 8.0, 24.0, 14.0));
    }

    #[test]
    fn rect_bounds_standardize_negative_size() {
        let a = ann(AnnotationKind::Rectangle { rect: Rect::new(50.0, 50.0, -20.0, -10.0) }, style(2.0));
        assert_eq!(a.bounds(), Rect::new(29.0, 39.0, 22.0, 12.0));
    }

    #[test]
    fn region_bounds_have_no_stroke_padding() {
        let a = ann(AnnotationKind::Redact { rect: Rect::new(1.0, 2.0, 3.0, 4.0) }, style(10.0));
        assert_eq!(a.bounds(), Rect::new(1.0, 2.0, 3.0, 4.0));
    }

    #[test]
    fn freehand_bounds_and_empty() {
        let pts = vec![Point::new(0.0, 5.0), Point::new(10.0, 0.0), Point::new(4.0, 9.0)];
        let a = ann(AnnotationKind::Freehand { points: pts }, style(2.0));
        assert_eq!(a.bounds(), Rect::new(-1.0, -1.0, 12.0, 11.0));
        let e = ann(AnnotationKind::Freehand { points: vec![] }, style(2.0));
        assert_eq!(e.bounds(), Rect::new(-1.0, -1.0, 2.0, 2.0));
        assert!(!e.hit_test(Point::new(0.0, 0.0), 5.0));
    }

    #[test]
    fn counter_and_text_bounds() {
        let s = Style { font_size: 10.0, ..Style::default() };
        let c = ann(AnnotationKind::Counter { center: Point::new(50.0, 50.0), number: 1 }, s);
        assert_eq!(c.bounds(), Rect::new(41.0, 41.0, 18.0, 18.0));
        let t = ann(AnnotationKind::Text { origin: Point::new(0.0, 0.0), text: "ab\nabcd".into() }, s);
        let b = t.bounds();
        assert!((b.width - 24.0).abs() < 1e-9 && (b.height - 24.0).abs() < 1e-9);
    }

    #[test]
    fn translate_moves_all_kinds() {
        let a = ann(AnnotationKind::Arrow { start: Point::new(0.0, 0.0), end: Point::new(5.0, 5.0) }, style(2.0));
        let b = a.translated(10.0, -2.0);
        assert_eq!(b.kind, AnnotationKind::Arrow { start: Point::new(10.0, -2.0), end: Point::new(15.0, 3.0) });
        let f = ann(AnnotationKind::Freehand { points: vec![Point::new(1.0, 1.0)] }, style(2.0)).translated(1.0, 1.0);
        assert_eq!(f.kind, AnnotationKind::Freehand { points: vec![Point::new(2.0, 2.0)] });
        let r = ann(AnnotationKind::Blur { rect: Rect::new(0.0, 0.0, 4.0, 4.0), radius: 3.0 }, style(1.0)).translated(2.0, 3.0);
        assert_eq!(r.bounds(), Rect::new(2.0, 3.0, 4.0, 4.0));
    }

    #[test]
    fn line_hit_uses_segment_distance() {
        let a = ann(AnnotationKind::Line { start: Point::new(0.0, 0.0), end: Point::new(100.0, 0.0) }, style(2.0));
        assert!(a.hit_test(Point::new(50.0, 3.0), 2.5));
        assert!(!a.hit_test(Point::new(50.0, 10.0), 2.0));
        // Past the endpoint the distance is to the end point, not the infinite line.
        assert!(!a.hit_test(Point::new(120.0, 0.0), 2.0));
        assert!(a.hit_test(Point::new(101.0, 0.0), 1.0));
    }

    #[test]
    fn degenerate_line_hits_like_a_point() {
        let a = ann(AnnotationKind::Line { start: Point::new(5.0, 5.0), end: Point::new(5.0, 5.0) }, style(2.0));
        assert!(a.hit_test(Point::new(5.0, 6.0), 0.0));
        assert!(!a.hit_test(Point::new(5.0, 9.0), 0.0));
    }

    #[test]
    fn freehand_hit() {
        let a = ann(
            AnnotationKind::Freehand { points: vec![Point::new(0.0, 0.0), Point::new(10.0, 0.0), Point::new(10.0, 10.0)] },
            style(2.0),
        );
        assert!(a.hit_test(Point::new(10.0, 5.0), 1.0));
        assert!(!a.hit_test(Point::new(0.0, 10.0), 1.0));
    }

    #[test]
    fn unfilled_rectangle_hits_outline_only() {
        let a = ann(AnnotationKind::Rectangle { rect: Rect::new(0.0, 0.0, 100.0, 100.0) }, style(2.0));
        assert!(a.hit_test(Point::new(0.0, 50.0), 2.0));
        assert!(a.hit_test(Point::new(98.0, 50.0), 2.0));
        assert!(!a.hit_test(Point::new(50.0, 50.0), 2.0));
    }

    #[test]
    fn filled_rectangle_hits_inside() {
        let s = Style { fill: Some(Color::RED), ..style(2.0) };
        let a = ann(AnnotationKind::Rectangle { rect: Rect::new(0.0, 0.0, 100.0, 100.0) }, s);
        assert!(a.hit_test(Point::new(50.0, 50.0), 0.0));
        assert!(!a.hit_test(Point::new(150.0, 50.0), 2.0));
    }

    #[test]
    fn ellipse_outline_and_fill() {
        let rect = Rect::new(0.0, 0.0, 100.0, 100.0);
        let open = ann(AnnotationKind::Ellipse { rect }, style(2.0));
        assert!(open.hit_test(Point::new(100.0, 50.0), 1.0));
        assert!(!open.hit_test(Point::new(50.0, 50.0), 1.0));
        let filled = ann(AnnotationKind::Ellipse { rect }, Style { fill: Some(Color::RED), ..style(2.0) });
        assert!(filled.hit_test(Point::new(50.0, 50.0), 0.0));
        // Corner of the bounding box is outside the ellipse.
        assert!(!filled.hit_test(Point::new(2.0, 2.0), 0.0));
    }

    #[test]
    fn region_kinds_hit_inside() {
        for kind in [
            AnnotationKind::Highlight { rect: Rect::new(0.0, 0.0, 10.0, 10.0) },
            AnnotationKind::Spotlight { rect: Rect::new(0.0, 0.0, 10.0, 10.0) },
            AnnotationKind::Redact { rect: Rect::new(0.0, 0.0, 10.0, 10.0) },
            AnnotationKind::Pixelate { rect: Rect::new(0.0, 0.0, 10.0, 10.0), block_size: 4 },
        ] {
            let a = ann(kind, style(1.0));
            assert!(a.hit_test(Point::new(5.0, 5.0), 0.0));
            assert!(!a.hit_test(Point::new(20.0, 5.0), 1.0));
        }
    }

    #[test]
    fn counter_and_text_hit() {
        let s = Style { font_size: 10.0, ..Style::default() };
        let c = ann(AnnotationKind::Counter { center: Point::new(50.0, 50.0), number: 2 }, s);
        assert!(c.hit_test(Point::new(55.0, 50.0), 0.0));
        assert!(!c.hit_test(Point::new(70.0, 50.0), 1.0));
        let t = ann(AnnotationKind::Text { origin: Point::new(0.0, 0.0), text: "hello".into() }, s);
        assert!(t.hit_test(Point::new(10.0, 5.0), 0.0));
        assert!(!t.hit_test(Point::new(100.0, 5.0), 0.0));
    }

    #[test]
    fn destructive_kinds() {
        let r = Rect::new(0.0, 0.0, 1.0, 1.0);
        assert!(AnnotationKind::Redact { rect: r }.is_destructive());
        assert!(AnnotationKind::Blur { rect: r, radius: 2.0 }.is_destructive());
        assert!(!AnnotationKind::Highlight { rect: r }.is_destructive());
    }

    #[test]
    fn core_rect_round_trip() {
        let r = Rect::new(1.0, 2.0, 3.0, 4.0);
        let c: snapora_core::geometry::Rect = r.into();
        assert_eq!(Rect::from(c), r);
    }
}
