//! Editor surface: `EditorDocument` plus Swift-facing mirrors of the editor
//! model types. Names that would shadow SwiftUI types are prefixed.

use std::sync::{Mutex, MutexGuard};

use snapora_editor as ed;

use crate::{Rect, SnaporaError};

impl From<ed::EditorError> for SnaporaError {
    fn from(e: ed::EditorError) -> Self {
        SnaporaError::Editor { message: e.to_string() }
    }
}

#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct EditorPoint {
    pub x: f64,
    pub y: f64,
}

#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct AnnotationColor {
    pub r: f32,
    pub g: f32,
    pub b: f32,
    pub a: f32,
}

#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct AnnotationStyle {
    pub stroke: AnnotationColor,
    pub fill: Option<AnnotationColor>,
    pub line_width: f64,
    pub font_size: f64,
}

#[derive(Debug, Clone, uniffi::Enum)]
pub enum AnnotationKind {
    Arrow { start: EditorPoint, end: EditorPoint },
    Line { start: EditorPoint, end: EditorPoint },
    Rectangle { rect: Rect },
    Ellipse { rect: Rect },
    Text { origin: EditorPoint, text: String },
    Freehand { points: Vec<EditorPoint> },
    Counter { center: EditorPoint, number: u32 },
    Highlight { rect: Rect },
    Spotlight { rect: Rect },
    Blur { rect: Rect, radius: f64 },
    Pixelate { rect: Rect, block_size: u32 },
    Redact { rect: Rect },
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct Annotation {
    pub id: u64,
    pub kind: AnnotationKind,
    pub style: AnnotationStyle,
}

impl From<EditorPoint> for ed::Point {
    fn from(p: EditorPoint) -> Self {
        ed::Point::new(p.x, p.y)
    }
}
impl From<ed::Point> for EditorPoint {
    fn from(p: ed::Point) -> Self {
        EditorPoint { x: p.x, y: p.y }
    }
}
impl From<AnnotationColor> for ed::Color {
    fn from(c: AnnotationColor) -> Self {
        ed::Color::new(c.r, c.g, c.b, c.a)
    }
}
impl From<ed::Color> for AnnotationColor {
    fn from(c: ed::Color) -> Self {
        AnnotationColor { r: c.r, g: c.g, b: c.b, a: c.a }
    }
}
impl From<AnnotationStyle> for ed::Style {
    fn from(s: AnnotationStyle) -> Self {
        ed::Style {
            stroke: s.stroke.into(),
            fill: s.fill.map(Into::into),
            line_width: s.line_width,
            font_size: s.font_size,
        }
    }
}
impl From<ed::Style> for AnnotationStyle {
    fn from(s: ed::Style) -> Self {
        AnnotationStyle {
            stroke: s.stroke.into(),
            fill: s.fill.map(Into::into),
            line_width: s.line_width,
            font_size: s.font_size,
        }
    }
}

fn to_ed_rect(r: Rect) -> ed::Rect {
    ed::Rect::new(r.x, r.y, r.width, r.height)
}
fn from_ed_rect(r: ed::Rect) -> Rect {
    Rect { x: r.x, y: r.y, width: r.width, height: r.height }
}

impl From<AnnotationKind> for ed::AnnotationKind {
    fn from(k: AnnotationKind) -> Self {
        use AnnotationKind as K;
        match k {
            K::Arrow { start, end } => Self::Arrow { start: start.into(), end: end.into() },
            K::Line { start, end } => Self::Line { start: start.into(), end: end.into() },
            K::Rectangle { rect } => Self::Rectangle { rect: to_ed_rect(rect) },
            K::Ellipse { rect } => Self::Ellipse { rect: to_ed_rect(rect) },
            K::Text { origin, text } => Self::Text { origin: origin.into(), text },
            K::Freehand { points } => {
                Self::Freehand { points: points.into_iter().map(Into::into).collect() }
            }
            K::Counter { center, number } => Self::Counter { center: center.into(), number },
            K::Highlight { rect } => Self::Highlight { rect: to_ed_rect(rect) },
            K::Spotlight { rect } => Self::Spotlight { rect: to_ed_rect(rect) },
            K::Blur { rect, radius } => Self::Blur { rect: to_ed_rect(rect), radius },
            K::Pixelate { rect, block_size } => {
                Self::Pixelate { rect: to_ed_rect(rect), block_size }
            }
            K::Redact { rect } => Self::Redact { rect: to_ed_rect(rect) },
        }
    }
}

impl From<ed::AnnotationKind> for AnnotationKind {
    fn from(k: ed::AnnotationKind) -> Self {
        use ed::AnnotationKind as K;
        match k {
            K::Arrow { start, end } => Self::Arrow { start: start.into(), end: end.into() },
            K::Line { start, end } => Self::Line { start: start.into(), end: end.into() },
            K::Rectangle { rect } => Self::Rectangle { rect: from_ed_rect(rect) },
            K::Ellipse { rect } => Self::Ellipse { rect: from_ed_rect(rect) },
            K::Text { origin, text } => Self::Text { origin: origin.into(), text },
            K::Freehand { points } => {
                Self::Freehand { points: points.into_iter().map(Into::into).collect() }
            }
            K::Counter { center, number } => Self::Counter { center: center.into(), number },
            K::Highlight { rect } => Self::Highlight { rect: from_ed_rect(rect) },
            K::Spotlight { rect } => Self::Spotlight { rect: from_ed_rect(rect) },
            K::Blur { rect, radius } => Self::Blur { rect: from_ed_rect(rect), radius },
            K::Pixelate { rect, block_size } => {
                Self::Pixelate { rect: from_ed_rect(rect), block_size }
            }
            K::Redact { rect } => Self::Redact { rect: from_ed_rect(rect) },
        }
    }
}

impl From<&ed::Annotation> for Annotation {
    fn from(a: &ed::Annotation) -> Self {
        Annotation { id: a.id.0, kind: a.kind.clone().into(), style: a.style.into() }
    }
}

/// Mutable annotated-image document with undo/redo.
#[derive(uniffi::Object)]
pub struct EditorDocument {
    inner: Mutex<ed::ImageDocument>,
}

impl EditorDocument {
    fn doc(&self) -> MutexGuard<'_, ed::ImageDocument> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }
}

#[uniffi::export]
impl EditorDocument {
    #[uniffi::constructor]
    pub fn new(width: u32, height: u32, source_path: Option<String>) -> Self {
        Self { inner: Mutex::new(ed::ImageDocument::new(width, height, source_path)) }
    }

    #[uniffi::constructor]
    pub fn from_json(json: String) -> Result<Self, SnaporaError> {
        Ok(Self { inner: Mutex::new(ed::ImageDocument::from_json(&json)?) })
    }

    pub fn to_json(&self) -> Result<String, SnaporaError> {
        Ok(self.doc().to_json()?)
    }

    pub fn width(&self) -> u32 {
        self.doc().width
    }

    pub fn height(&self) -> u32 {
        self.doc().height
    }

    pub fn source_path(&self) -> Option<String> {
        self.doc().source_path.clone()
    }

    /// Annotations back to front (last is topmost).
    pub fn annotations(&self) -> Vec<Annotation> {
        self.doc().annotations.iter().map(Annotation::from).collect()
    }

    pub fn annotation(&self, id: u64) -> Option<Annotation> {
        self.doc().annotation(ed::AnnotationId(id)).map(Annotation::from)
    }

    pub fn add_annotation(
        &self,
        kind: AnnotationKind,
        style: AnnotationStyle,
    ) -> Result<u64, SnaporaError> {
        Ok(self.doc().add_annotation(kind.into(), style.into())?.0)
    }

    pub fn update_annotation(
        &self,
        id: u64,
        kind: AnnotationKind,
        style: AnnotationStyle,
    ) -> Result<(), SnaporaError> {
        Ok(self.doc().update(ed::AnnotationId(id), kind.into(), style.into())?)
    }

    pub fn remove_annotation(&self, id: u64) -> Result<(), SnaporaError> {
        Ok(self.doc().remove(ed::AnnotationId(id))?)
    }

    pub fn move_annotations(&self, ids: Vec<u64>, dx: f64, dy: f64) -> Result<(), SnaporaError> {
        let ids: Vec<_> = ids.into_iter().map(ed::AnnotationId).collect();
        Ok(self.doc().move_annotations(&ids, dx, dy)?)
    }

    pub fn bring_to_front(&self, id: u64) -> Result<(), SnaporaError> {
        Ok(self.doc().bring_to_front(ed::AnnotationId(id))?)
    }

    pub fn annotation_at(&self, x: f64, y: f64, tolerance: f64) -> Option<u64> {
        self.doc().annotation_at(ed::Point::new(x, y), tolerance).map(|i| i.0)
    }

    pub fn next_counter_number(&self) -> u32 {
        self.doc().next_counter_number()
    }

    pub fn set_crop(&self, crop: Option<Rect>) -> Result<(), SnaporaError> {
        Ok(self.doc().set_crop(crop.map(to_ed_rect))?)
    }

    pub fn crop(&self) -> Option<Rect> {
        self.doc().crop.map(from_ed_rect)
    }

    /// Clockwise quarter turns, 0...3.
    pub fn rotation(&self) -> u8 {
        self.doc().rotation
    }

    pub fn rotate_clockwise(&self) -> Result<(), SnaporaError> {
        Ok(self.doc().rotate_clockwise()?)
    }

    pub fn rotate_counter_clockwise(&self) -> Result<(), SnaporaError> {
        Ok(self.doc().rotate_counter_clockwise()?)
    }

    pub fn clear_annotations(&self) -> Result<(), SnaporaError> {
        Ok(self.doc().clear_annotations()?)
    }

    pub fn undo(&self) -> bool {
        self.doc().undo()
    }

    pub fn redo(&self) -> bool {
        self.doc().redo()
    }

    pub fn can_undo(&self) -> bool {
        self.doc().can_undo()
    }

    pub fn can_redo(&self) -> bool {
        self.doc().can_redo()
    }

    /// Bounds of every Redact/Blur/Pixelate annotation; exporters must bake them in.
    pub fn destructive_regions(&self) -> Vec<Rect> {
        self.doc().destructive_regions().into_iter().map(from_ed_rect).collect()
    }

    /// `(width, height)` in pixels after crop and rotation.
    pub fn output_size(&self) -> OutputSize {
        let (width, height) = self.doc().output_size();
        OutputSize { width, height }
    }
}

#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct OutputSize {
    pub width: f64,
    pub height: f64,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn style() -> AnnotationStyle {
        ed::Style::default().into()
    }

    #[test]
    fn add_undo_redo_and_json_round_trip() {
        let doc = EditorDocument::new(100, 50, Some("/tmp/a.png".into()));
        let id = doc
            .add_annotation(AnnotationKind::Redact { rect: Rect { x: 1.0, y: 2.0, width: 10.0, height: 5.0 } }, style())
            .unwrap();
        assert_eq!(doc.annotations().len(), 1);
        assert_eq!(doc.destructive_regions().len(), 1);
        assert_eq!(doc.annotation_at(3.0, 3.0, 1.0), Some(id));
        assert!(doc.undo());
        assert!(doc.annotations().is_empty() && doc.can_redo());
        assert!(doc.redo());

        let json = doc.to_json().unwrap();
        let back = EditorDocument::from_json(json).unwrap();
        assert_eq!(back.annotations().len(), 1);
        assert_eq!(back.source_path().as_deref(), Some("/tmp/a.png"));
        assert!(!back.can_undo());
    }

    #[test]
    fn errors_map_to_editor_variant() {
        let doc = EditorDocument::new(10, 10, None);
        assert!(matches!(doc.remove_annotation(9), Err(SnaporaError::Editor { .. })));
        assert!(matches!(EditorDocument::from_json("nope".into()), Err(SnaporaError::Editor { .. })));
    }

    #[test]
    fn crop_rotation_and_kind_round_trip() {
        let doc = EditorDocument::new(100, 50, None);
        doc.set_crop(Some(Rect { x: 0.0, y: 0.0, width: 40.0, height: 20.0 })).unwrap();
        doc.rotate_clockwise().unwrap();
        assert_eq!(doc.rotation(), 1);
        let s = doc.output_size();
        assert_eq!((s.width, s.height), (20.0, 40.0));
        let k = AnnotationKind::Freehand { points: vec![EditorPoint { x: 1.0, y: 2.0 }] };
        let id = doc.add_annotation(k, style()).unwrap();
        assert!(matches!(doc.annotation(id).unwrap().kind, AnnotationKind::Freehand { .. }));
    }
}
