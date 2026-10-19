//! The image document, its reversible edit model, and undo/redo history.

use serde::{Deserialize, Serialize};

use crate::error::EditorError;
use crate::model::{Annotation, AnnotationId, AnnotationKind, Point, Rect, Style};

/// Current on-disk document format version.
pub const DOCUMENT_VERSION: u32 = 1;
/// Maximum number of undoable steps retained.
pub const MAX_HISTORY: usize = 200;

/// A user-facing edit request. Applied with [`ImageDocument::apply`].
#[derive(Debug, Clone, PartialEq)]
pub enum Edit {
    /// Append an annotation on top of the stack.
    Add(Annotation),
    /// Remove an annotation by id.
    Remove(AnnotationId),
    /// Replace an annotation; `before` must equal the current value.
    Update { id: AnnotationId, before: Annotation, after: Annotation },
    /// Translate the given annotations.
    Move { ids: Vec<AnnotationId>, dx: f64, dy: f64 },
    /// Move an annotation to `to_index` in z-order (last = topmost).
    Reorder { id: AnnotationId, to_index: usize },
    /// Change the crop; `before` must equal the current crop.
    SetCrop { before: Option<Rect>, after: Option<Rect> },
    /// Rotate by clockwise quarter turns (added modulo 4).
    Rotate { quarter_turns: u8 },
    /// Remove every annotation.
    Clear,
}

/// Fully resolved, self-inverting operations stored in history.
#[derive(Debug, Clone, PartialEq)]
enum Op {
    Insert { index: usize, annotation: Annotation },
    Delete { index: usize, annotation: Annotation },
    Replace { before: Annotation, after: Annotation },
    Move { ids: Vec<AnnotationId>, dx: f64, dy: f64 },
    Reorder { from: usize, to: usize },
    SetCrop { before: Option<Rect>, after: Option<Rect> },
    SetRotation { before: u8, after: u8 },
    SetAnnotations { before: Vec<Annotation>, after: Vec<Annotation> },
}

impl Op {
    fn inverse(&self) -> Op {
        match self.clone() {
            Op::Insert { index, annotation } => Op::Delete { index, annotation },
            Op::Delete { index, annotation } => Op::Insert { index, annotation },
            Op::Replace { before, after } => Op::Replace { before: after, after: before },
            Op::Move { ids, dx, dy } => Op::Move { ids, dx: -dx, dy: -dy },
            Op::Reorder { from, to } => Op::Reorder { from: to, to: from },
            Op::SetCrop { before, after } => Op::SetCrop { before: after, after: before },
            Op::SetRotation { before, after } => Op::SetRotation { before: after, after: before },
            Op::SetAnnotations { before, after } => Op::SetAnnotations { before: after, after: before },
        }
    }
}

/// A platform-neutral image document: source metadata, ordered annotations,
/// crop/rotation state, and undo/redo history (history is not serialized).
///
/// # Redaction
///
/// `Redact`, `Blur` and `Pixelate` annotations must be baked into exported
/// pixels by the renderer. [`ImageDocument::destructive_regions`] lists them
/// so the exporter can verify none were skipped.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ImageDocument {
    pub version: u32,
    pub width: u32,
    pub height: u32,
    pub source_path: Option<String>,
    /// Back-to-front z-order; the last element is topmost.
    pub annotations: Vec<Annotation>,
    /// Crop in source pixels (before rotation).
    pub crop: Option<Rect>,
    /// Clockwise quarter turns, `0..=3`.
    pub rotation: u8,
    pub next_id: u64,
    #[serde(skip)]
    undo_stack: Vec<Op>,
    #[serde(skip)]
    redo_stack: Vec<Op>,
}

impl ImageDocument {
    /// Creates an empty document for an image of `width` x `height` pixels.
    pub fn new(width: u32, height: u32, source_path: Option<String>) -> Self {
        Self {
            version: DOCUMENT_VERSION,
            width,
            height,
            source_path,
            annotations: Vec::new(),
            crop: None,
            rotation: 0,
            next_id: 1,
            undo_stack: Vec::new(),
            redo_stack: Vec::new(),
        }
    }

    // ---- queries -------------------------------------------------------

    pub fn annotation(&self, id: AnnotationId) -> Option<&Annotation> {
        self.annotations.iter().find(|a| a.id == id)
    }

    fn index_of(&self, id: AnnotationId) -> Result<usize, EditorError> {
        self.annotations.iter().position(|a| a.id == id).ok_or(EditorError::NotFound(id))
    }

    /// Topmost annotation hit by `point` within `tolerance`, if any.
    pub fn annotation_at(&self, point: Point, tolerance: f64) -> Option<AnnotationId> {
        self.annotations.iter().rev().find(|a| a.hit_test(point, tolerance)).map(|a| a.id)
    }

    /// Number for the next counter badge: highest existing number + 1.
    pub fn next_counter_number(&self) -> u32 {
        self.annotations
            .iter()
            .filter_map(|a| match a.kind {
                AnnotationKind::Counter { number, .. } => Some(number),
                _ => None,
            })
            .max()
            .map_or(1, |n| n.saturating_add(1))
    }

    /// Bounds of every Redact/Blur/Pixelate annotation. The renderer must
    /// bake each into exported pixels; exporters can use this to verify.
    pub fn destructive_regions(&self) -> Vec<Rect> {
        self.annotations
            .iter()
            .filter(|a| a.kind.is_destructive())
            .map(|a| a.bounds())
            .collect()
    }

    /// Size in pixels after crop (rotation swaps axes for odd turns).
    pub fn output_size(&self) -> (f64, f64) {
        let (w, h) = match self.crop {
            Some(c) => (c.width, c.height),
            None => (f64::from(self.width), f64::from(self.height)),
        };
        if self.rotation % 2 == 1 { (h, w) } else { (w, h) }
    }

    /// Checks `rect` is finite, non-empty and inside the image.
    pub fn validate_crop(&self, rect: &Rect) -> Result<(), EditorError> {
        let eps = 1e-6;
        if !rect.is_finite()
            || rect.width <= 0.0
            || rect.height <= 0.0
            || rect.x < -eps
            || rect.y < -eps
            || rect.max_x() > f64::from(self.width) + eps
            || rect.max_y() > f64::from(self.height) + eps
        {
            return Err(EditorError::InvalidCrop);
        }
        Ok(())
    }

    // ---- history -------------------------------------------------------

    pub fn can_undo(&self) -> bool {
        !self.undo_stack.is_empty()
    }

    pub fn can_redo(&self) -> bool {
        !self.redo_stack.is_empty()
    }

    /// Reverts the most recent edit. Returns `false` if there is nothing to undo.
    pub fn undo(&mut self) -> bool {
        let Some(op) = self.undo_stack.pop() else { return false };
        self.run(&op.inverse());
        self.redo_stack.push(op);
        true
    }

    /// Re-applies the most recently undone edit. Returns `false` if none.
    pub fn redo(&mut self) -> bool {
        let Some(op) = self.redo_stack.pop() else { return false };
        self.run(&op);
        self.undo_stack.push(op);
        true
    }

    /// Validates and applies an edit, recording it for undo and clearing redo.
    pub fn apply(&mut self, edit: Edit) -> Result<(), EditorError> {
        let Some(op) = self.resolve(edit)? else { return Ok(()) };
        self.run(&op);
        self.redo_stack.clear();
        self.undo_stack.push(op);
        if self.undo_stack.len() > MAX_HISTORY {
            let excess = self.undo_stack.len() - MAX_HISTORY;
            self.undo_stack.drain(..excess);
        }
        Ok(())
    }

    /// Validates an edit against the current state and lowers it to an `Op`.
    /// `Ok(None)` means the edit is a no-op.
    fn resolve(&self, edit: Edit) -> Result<Option<Op>, EditorError> {
        match edit {
            Edit::Add(annotation) => {
                if self.annotation(annotation.id).is_some() {
                    return Err(EditorError::DuplicateId(annotation.id));
                }
                validate_annotation(&annotation)?;
                Ok(Some(Op::Insert { index: self.annotations.len(), annotation }))
            }
            Edit::Remove(id) => {
                let index = self.index_of(id)?;
                Ok(Some(Op::Delete { index, annotation: self.annotations[index].clone() }))
            }
            Edit::Update { id, before, after } => {
                let index = self.index_of(id)?;
                if self.annotations[index] != before {
                    return Err(EditorError::Stale);
                }
                if after.id != id {
                    return Err(EditorError::InvalidValue("update must not change the annotation id"));
                }
                validate_annotation(&after)?;
                Ok(Some(Op::Replace { before, after }))
            }
            Edit::Move { ids, dx, dy } => {
                if !dx.is_finite() || !dy.is_finite() {
                    return Err(EditorError::InvalidValue("move offset must be finite"));
                }
                for id in &ids {
                    self.index_of(*id)?;
                }
                if ids.is_empty() || (dx == 0.0 && dy == 0.0) {
                    return Ok(None);
                }
                Ok(Some(Op::Move { ids, dx, dy }))
            }
            Edit::Reorder { id, to_index } => {
                let from = self.index_of(id)?;
                let to = to_index.min(self.annotations.len() - 1);
                Ok((from != to).then_some(Op::Reorder { from, to }))
            }
            Edit::SetCrop { before, after } => {
                if self.crop != before {
                    return Err(EditorError::Stale);
                }
                if let Some(rect) = &after {
                    self.validate_crop(rect)?;
                }
                Ok((before != after).then_some(Op::SetCrop { before, after }))
            }
            Edit::Rotate { quarter_turns } => {
                let after = ((u32::from(self.rotation) + u32::from(quarter_turns)) % 4) as u8;
                Ok((after != self.rotation).then_some(Op::SetRotation { before: self.rotation, after }))
            }
            Edit::Clear => {
                if self.annotations.is_empty() {
                    return Ok(None);
                }
                Ok(Some(Op::SetAnnotations { before: self.annotations.clone(), after: Vec::new() }))
            }
        }
    }

    /// Applies a resolved op. Ops are validated at creation, so this cannot fail.
    fn run(&mut self, op: &Op) {
        match op {
            Op::Insert { index, annotation } => {
                self.next_id = self.next_id.max(annotation.id.0.saturating_add(1));
                self.annotations.insert(*index, annotation.clone());
            }
            Op::Delete { index, .. } => {
                self.annotations.remove(*index);
            }
            Op::Replace { before, after } => {
                if let Some(slot) = self.annotations.iter_mut().find(|a| a.id == before.id) {
                    *slot = after.clone();
                }
            }
            Op::Move { ids, dx, dy } => {
                for a in self.annotations.iter_mut().filter(|a| ids.contains(&a.id)) {
                    a.translate(*dx, *dy);
                }
            }
            Op::Reorder { from, to } => {
                let a = self.annotations.remove(*from);
                self.annotations.insert(*to, a);
            }
            Op::SetCrop { after, .. } => self.crop = *after,
            Op::SetRotation { after, .. } => self.rotation = *after,
            Op::SetAnnotations { after, .. } => self.annotations = after.clone(),
        }
    }

    // ---- conveniences --------------------------------------------------

    /// Adds an annotation with a freshly allocated id.
    pub fn add_annotation(&mut self, kind: AnnotationKind, style: Style) -> Result<AnnotationId, EditorError> {
        let id = AnnotationId(self.next_id);
        self.apply(Edit::Add(Annotation::new(id, kind, style)))?;
        Ok(id)
    }

    pub fn remove(&mut self, id: AnnotationId) -> Result<(), EditorError> {
        self.apply(Edit::Remove(id))
    }

    /// Replaces the kind and style of an annotation.
    pub fn update(&mut self, id: AnnotationId, kind: AnnotationKind, style: Style) -> Result<(), EditorError> {
        let before = self.annotation(id).ok_or(EditorError::NotFound(id))?.clone();
        let after = Annotation::new(id, kind, style);
        self.apply(Edit::Update { id, before, after })
    }

    pub fn move_annotations(&mut self, ids: &[AnnotationId], dx: f64, dy: f64) -> Result<(), EditorError> {
        self.apply(Edit::Move { ids: ids.to_vec(), dx, dy })
    }

    pub fn bring_to_front(&mut self, id: AnnotationId) -> Result<(), EditorError> {
        self.apply(Edit::Reorder { id, to_index: usize::MAX })
    }

    /// Sets (or clears) the crop rectangle.
    pub fn set_crop(&mut self, crop: Option<Rect>) -> Result<(), EditorError> {
        self.apply(Edit::SetCrop { before: self.crop, after: crop })
    }

    /// Rotates 90 degrees clockwise.
    pub fn rotate_clockwise(&mut self) -> Result<(), EditorError> {
        self.apply(Edit::Rotate { quarter_turns: 1 })
    }

    /// Rotates 90 degrees counter-clockwise.
    pub fn rotate_counter_clockwise(&mut self) -> Result<(), EditorError> {
        self.apply(Edit::Rotate { quarter_turns: 3 })
    }

    pub fn clear_annotations(&mut self) -> Result<(), EditorError> {
        self.apply(Edit::Clear)
    }

    // ---- serialization -------------------------------------------------

    /// Serializes the document (without undo history).
    pub fn to_json(&self) -> Result<String, EditorError> {
        serde_json::to_string(self).map_err(|e| EditorError::Malformed(e.to_string()))
    }

    /// Parses and validates a document. Rejects versions newer than
    /// [`DOCUMENT_VERSION`] before attempting to interpret the body.
    pub fn from_json(json: &str) -> Result<Self, EditorError> {
        let value: serde_json::Value =
            serde_json::from_str(json).map_err(|e| EditorError::Malformed(e.to_string()))?;
        let found = value
            .get("version")
            .and_then(serde_json::Value::as_u64)
            .ok_or_else(|| EditorError::Malformed("missing version".into()))?;
        if found > u64::from(DOCUMENT_VERSION) {
            return Err(EditorError::UnsupportedVersion {
                found: u32::try_from(found).unwrap_or(u32::MAX),
                supported: DOCUMENT_VERSION,
            });
        }
        let mut doc: ImageDocument =
            serde_json::from_value(value).map_err(|e| EditorError::Malformed(e.to_string()))?;
        if doc.rotation > 3 {
            return Err(EditorError::InvalidValue("rotation must be 0..=3"));
        }
        if let Some(crop) = doc.crop {
            doc.validate_crop(&crop)?;
        }
        for (i, a) in doc.annotations.iter().enumerate() {
            if a.id.0 == 0 {
                return Err(EditorError::Malformed("annotation id 0 is reserved".into()));
            }
            validate_annotation(a)?;
            if doc.annotations[..i].iter().any(|b| b.id == a.id) {
                return Err(EditorError::DuplicateId(a.id));
            }
        }
        let min_next = doc.annotations.iter().map(|a| a.id.0.saturating_add(1)).max().unwrap_or(1);
        doc.next_id = doc.next_id.max(min_next).max(1);
        Ok(doc)
    }
}

fn validate_annotation(a: &Annotation) -> Result<(), EditorError> {
    let finite = |p: &Point| p.x.is_finite() && p.y.is_finite();
    let ok = match &a.kind {
        AnnotationKind::Arrow { start, end } | AnnotationKind::Line { start, end } => finite(start) && finite(end),
        AnnotationKind::Rectangle { rect }
        | AnnotationKind::Ellipse { rect }
        | AnnotationKind::Highlight { rect }
        | AnnotationKind::Spotlight { rect }
        | AnnotationKind::Redact { rect } => rect.is_finite(),
        AnnotationKind::Blur { rect, radius } => rect.is_finite() && radius.is_finite() && *radius >= 0.0,
        AnnotationKind::Pixelate { rect, block_size } => rect.is_finite() && *block_size > 0,
        AnnotationKind::Text { origin, .. } => finite(origin),
        AnnotationKind::Freehand { points } => points.iter().all(finite),
        AnnotationKind::Counter { center, .. } => finite(center),
    };
    if !ok || !a.style.line_width.is_finite() || !a.style.font_size.is_finite() {
        return Err(EditorError::InvalidValue("annotation contains non-finite or out-of-range values"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn doc() -> ImageDocument {
        ImageDocument::new(200, 100, Some("/tmp/a.png".into()))
    }

    fn rect_kind(x: f64) -> AnnotationKind {
        AnnotationKind::Rectangle { rect: Rect::new(x, 10.0, 20.0, 20.0) }
    }

    fn filled() -> Style {
        Style { fill: Some(crate::model::Color::RED), ..Style::default() }
    }

    #[test]
    fn add_undo_redo() {
        let mut d = doc();
        let id = d.add_annotation(rect_kind(0.0), Style::default()).unwrap();
        assert_eq!(d.annotations.len(), 1);
        assert!(d.can_undo() && !d.can_redo());
        assert!(d.undo());
        assert!(d.annotations.is_empty());
        assert!(!d.can_undo() && d.can_redo());
        assert!(d.redo());
        assert_eq!(d.annotations[0].id, id);
        assert!(!d.redo());
    }

    #[test]
    fn ids_are_unique_and_not_reused_after_undo() {
        let mut d = doc();
        let a = d.add_annotation(rect_kind(0.0), Style::default()).unwrap();
        d.undo();
        let b = d.add_annotation(rect_kind(0.0), Style::default()).unwrap();
        assert_ne!(a, b);
    }

    #[test]
    fn duplicate_id_rejected() {
        let mut d = doc();
        let id = d.add_annotation(rect_kind(0.0), Style::default()).unwrap();
        let dup = Annotation::new(id, rect_kind(5.0), Style::default());
        assert_eq!(d.apply(Edit::Add(dup)), Err(EditorError::DuplicateId(id)));
    }

    #[test]
    fn remove_restores_at_original_index() {
        let mut d = doc();
        let a = d.add_annotation(rect_kind(0.0), Style::default()).unwrap();
        let b = d.add_annotation(rect_kind(1.0), Style::default()).unwrap();
        let c = d.add_annotation(rect_kind(2.0), Style::default()).unwrap();
        d.remove(b).unwrap();
        assert_eq!(d.annotations.iter().map(|x| x.id).collect::<Vec<_>>(), vec![a, c]);
        d.undo();
        assert_eq!(d.annotations.iter().map(|x| x.id).collect::<Vec<_>>(), vec![a, b, c]);
        assert_eq!(d.remove(AnnotationId(99)), Err(EditorError::NotFound(AnnotationId(99))));
    }

    #[test]
    fn update_undo_redo_and_stale_detection() {
        let mut d = doc();
        let id = d.add_annotation(rect_kind(0.0), Style::default()).unwrap();
        d.update(id, rect_kind(50.0), filled()).unwrap();
        assert_eq!(d.annotation(id).unwrap().kind, rect_kind(50.0));
        d.undo();
        assert_eq!(d.annotation(id).unwrap().kind, rect_kind(0.0));
        d.redo();
        assert_eq!(d.annotation(id).unwrap().style, filled());

        let stale = Annotation::new(id, rect_kind(1.0), Style::default());
        let after = Annotation::new(id, rect_kind(2.0), Style::default());
        assert_eq!(d.apply(Edit::Update { id, before: stale, after }), Err(EditorError::Stale));
        let cur = d.annotation(id).unwrap().clone();
        let wrong_id = Annotation::new(AnnotationId(77), rect_kind(2.0), Style::default());
        assert!(matches!(
            d.apply(Edit::Update { id, before: cur, after: wrong_id }),
            Err(EditorError::InvalidValue(_))
        ));
    }

    #[test]
    fn move_and_undo() {
        let mut d = doc();
        let a = d.add_annotation(rect_kind(0.0), Style::default()).unwrap();
        let b = d.add_annotation(rect_kind(100.0), Style::default()).unwrap();
        d.move_annotations(&[a, b], 5.0, -2.0).unwrap();
        assert_eq!(d.annotation(a).unwrap().kind, AnnotationKind::Rectangle { rect: Rect::new(5.0, 8.0, 20.0, 20.0) });
        d.undo();
        assert_eq!(d.annotation(a).unwrap().kind, rect_kind(0.0));
        assert_eq!(d.annotation(b).unwrap().kind, rect_kind(100.0));
        assert!(d.move_annotations(&[a, AnnotationId(42)], 1.0, 1.0).is_err());
        assert!(d.move_annotations(&[a], f64::NAN, 0.0).is_err());
    }

    #[test]
    fn zero_move_is_not_recorded() {
        let mut d = doc();
        let a = d.add_annotation(rect_kind(0.0), Style::default()).unwrap();
        d.undo();
        d.redo();
        d.move_annotations(&[a], 0.0, 0.0).unwrap();
        // Redo stack is untouched only if nothing was recorded; undo goes straight to add.
        d.undo();
        assert!(d.annotations.is_empty());
    }

    #[test]
    fn bring_to_front_reorders_and_undoes() {
        let mut d = doc();
        let a = d.add_annotation(rect_kind(0.0), Style::default()).unwrap();
        let b = d.add_annotation(rect_kind(1.0), Style::default()).unwrap();
        let c = d.add_annotation(rect_kind(2.0), Style::default()).unwrap();
        d.bring_to_front(a).unwrap();
        assert_eq!(d.annotations.iter().map(|x| x.id).collect::<Vec<_>>(), vec![b, c, a]);
        d.undo();
        assert_eq!(d.annotations.iter().map(|x| x.id).collect::<Vec<_>>(), vec![a, b, c]);
        // Already on top: no history entry.
        d.bring_to_front(c).unwrap();
        d.undo();
        assert_eq!(d.annotations.len(), 2);
    }

    #[test]
    fn redo_cleared_after_new_edit() {
        let mut d = doc();
        d.add_annotation(rect_kind(0.0), Style::default()).unwrap();
        d.undo();
        assert!(d.can_redo());
        d.add_annotation(rect_kind(1.0), Style::default()).unwrap();
        assert!(!d.can_redo());
        assert!(!d.redo());
    }

    #[test]
    fn failed_edit_keeps_redo() {
        let mut d = doc();
        d.add_annotation(rect_kind(0.0), Style::default()).unwrap();
        d.undo();
        assert!(d.remove(AnnotationId(500)).is_err());
        assert!(d.can_redo());
    }

    #[test]
    fn history_is_capped() {
        let mut d = doc();
        for i in 0..(MAX_HISTORY + 50) {
            d.add_annotation(rect_kind(i as f64), Style::default()).unwrap();
        }
        let mut undone = 0;
        while d.undo() {
            undone += 1;
        }
        assert_eq!(undone, MAX_HISTORY);
        assert_eq!(d.annotations.len(), 50);
    }

    #[test]
    fn clear_undo_restores_order() {
        let mut d = doc();
        let a = d.add_annotation(rect_kind(0.0), Style::default()).unwrap();
        let b = d.add_annotation(rect_kind(1.0), Style::default()).unwrap();
        d.clear_annotations().unwrap();
        assert!(d.annotations.is_empty());
        d.undo();
        assert_eq!(d.annotations.iter().map(|x| x.id).collect::<Vec<_>>(), vec![a, b]);
        d.redo();
        assert!(d.annotations.is_empty());
        // Clearing an empty document records nothing.
        d.clear_annotations().unwrap();
        d.undo();
        assert_eq!(d.annotations.len(), 2);
    }

    #[test]
    fn mixed_undo_redo_sequence() {
        let mut d = doc();
        let a = d.add_annotation(rect_kind(0.0), Style::default()).unwrap();
        d.move_annotations(&[a], 10.0, 0.0).unwrap();
        d.set_crop(Some(Rect::new(0.0, 0.0, 50.0, 50.0))).unwrap();
        d.rotate_clockwise().unwrap();
        d.remove(a).unwrap();
        for _ in 0..5 {
            assert!(d.undo());
        }
        assert!(!d.undo());
        assert!(d.annotations.is_empty() && d.crop.is_none() && d.rotation == 0);
        for _ in 0..5 {
            assert!(d.redo());
        }
        assert!(d.annotations.is_empty());
        assert_eq!(d.crop, Some(Rect::new(0.0, 0.0, 50.0, 50.0)));
        assert_eq!(d.rotation, 1);
    }

    #[test]
    fn crop_validation() {
        let mut d = doc();
        assert!(d.set_crop(Some(Rect::new(10.0, 10.0, 100.0, 50.0))).is_ok());
        assert_eq!(d.set_crop(Some(Rect::new(150.0, 0.0, 100.0, 50.0))), Err(EditorError::InvalidCrop));
        assert_eq!(d.set_crop(Some(Rect::new(-1.0, 0.0, 10.0, 10.0))), Err(EditorError::InvalidCrop));
        assert_eq!(d.set_crop(Some(Rect::new(0.0, 0.0, 0.0, 10.0))), Err(EditorError::InvalidCrop));
        assert_eq!(d.set_crop(Some(Rect::new(0.0, 0.0, f64::NAN, 10.0))), Err(EditorError::InvalidCrop));
        assert!(d.set_crop(Some(Rect::new(0.0, 0.0, 200.0, 100.0))).is_ok());
        assert_eq!(d.output_size(), (200.0, 100.0));
        d.set_crop(None).unwrap();
        assert!(d.crop.is_none());
        d.undo();
        assert_eq!(d.crop, Some(Rect::new(0.0, 0.0, 200.0, 100.0)));
    }

    #[test]
    fn set_crop_stale_before_rejected() {
        let mut d = doc();
        let r = Rect::new(0.0, 0.0, 10.0, 10.0);
        assert_eq!(d.apply(Edit::SetCrop { before: Some(r), after: None }), Err(EditorError::Stale));
    }

    #[test]
    fn rotation_wraps_and_swaps_output_size() {
        let mut d = doc();
        d.rotate_clockwise().unwrap();
        assert_eq!(d.output_size(), (100.0, 200.0));
        d.rotate_counter_clockwise().unwrap();
        d.rotate_counter_clockwise().unwrap();
        assert_eq!(d.rotation, 3);
        d.apply(Edit::Rotate { quarter_turns: 4 }).unwrap(); // no-op
        assert_eq!(d.rotation, 3);
        d.undo();
        assert_eq!(d.rotation, 0);
    }

    #[test]
    fn counter_numbering() {
        let mut d = doc();
        assert_eq!(d.next_counter_number(), 1);
        let n = d.next_counter_number();
        d.add_annotation(AnnotationKind::Counter { center: Point::new(1.0, 1.0), number: n }, Style::default()).unwrap();
        let c5 = d
            .add_annotation(AnnotationKind::Counter { center: Point::new(2.0, 2.0), number: 5 }, Style::default())
            .unwrap();
        assert_eq!(d.next_counter_number(), 6);
        d.remove(c5).unwrap();
        assert_eq!(d.next_counter_number(), 2);
        d.undo();
        assert_eq!(d.next_counter_number(), 6);
    }

    #[test]
    fn annotation_at_returns_topmost() {
        let mut d = doc();
        let under = d.add_annotation(rect_kind(0.0), filled()).unwrap();
        let over = d.add_annotation(rect_kind(5.0), filled()).unwrap();
        assert_eq!(d.annotation_at(Point::new(10.0, 15.0), 1.0), Some(over));
        d.bring_to_front(under).unwrap();
        assert_eq!(d.annotation_at(Point::new(10.0, 15.0), 1.0), Some(under));
        assert_eq!(d.annotation_at(Point::new(190.0, 90.0), 1.0), None);
    }

    #[test]
    fn destructive_regions_listed() {
        let mut d = doc();
        d.add_annotation(rect_kind(0.0), Style::default()).unwrap();
        d.add_annotation(AnnotationKind::Redact { rect: Rect::new(1.0, 1.0, 10.0, 10.0) }, Style::default()).unwrap();
        d.add_annotation(AnnotationKind::Blur { rect: Rect::new(20.0, 1.0, 10.0, 10.0), radius: 5.0 }, Style::default()).unwrap();
        d.add_annotation(AnnotationKind::Pixelate { rect: Rect::new(40.0, 1.0, 10.0, 10.0), block_size: 8 }, Style::default()).unwrap();
        assert_eq!(
            d.destructive_regions(),
            vec![Rect::new(1.0, 1.0, 10.0, 10.0), Rect::new(20.0, 1.0, 10.0, 10.0), Rect::new(40.0, 1.0, 10.0, 10.0)]
        );
    }

    #[test]
    fn invalid_annotation_values_rejected() {
        let mut d = doc();
        assert!(d.add_annotation(AnnotationKind::Pixelate { rect: Rect::new(0.0, 0.0, 1.0, 1.0), block_size: 0 }, Style::default()).is_err());
        assert!(d.add_annotation(AnnotationKind::Arrow { start: Point::new(f64::NAN, 0.0), end: Point::new(1.0, 1.0) }, Style::default()).is_err());
        assert!(!d.can_undo());
    }

    #[test]
    fn json_round_trip_without_history() {
        let mut d = doc();
        d.add_annotation(rect_kind(3.0), filled()).unwrap();
        d.add_annotation(AnnotationKind::Text { origin: Point::new(1.0, 2.0), text: "hi".into() }, Style::default()).unwrap();
        d.add_annotation(AnnotationKind::Freehand { points: vec![Point::new(0.0, 0.0), Point::new(3.0, 4.0)] }, Style::default()).unwrap();
        d.set_crop(Some(Rect::new(1.0, 1.0, 50.0, 50.0))).unwrap();
        d.rotate_clockwise().unwrap();
        let json = d.to_json().unwrap();
        let back = ImageDocument::from_json(&json).unwrap();
        assert_eq!(back, ImageDocument { undo_stack: vec![], redo_stack: vec![], ..d.clone() });
        assert!(!back.can_undo());
        assert_eq!(back.next_id, d.next_id);
    }

    #[test]
    fn json_rejects_future_version() {
        let mut d = doc();
        d.version = DOCUMENT_VERSION + 1;
        let json = d.to_json().unwrap();
        assert_eq!(
            ImageDocument::from_json(&json),
            Err(EditorError::UnsupportedVersion { found: DOCUMENT_VERSION + 1, supported: DOCUMENT_VERSION })
        );
        // Even a body this version cannot parse reports the version problem.
        assert!(matches!(
            ImageDocument::from_json(r#"{"version": 99, "weird": true}"#),
            Err(EditorError::UnsupportedVersion { found: 99, .. })
        ));
    }

    #[test]
    fn json_rejects_malformed_and_invalid() {
        assert!(matches!(ImageDocument::from_json("not json"), Err(EditorError::Malformed(_))));
        assert!(matches!(ImageDocument::from_json("{}"), Err(EditorError::Malformed(_))));
        let mut d = doc();
        d.rotation = 7;
        assert!(ImageDocument::from_json(&d.to_json().unwrap()).is_err());
        let mut d = doc();
        d.crop = Some(Rect::new(0.0, 0.0, 999.0, 10.0));
        assert_eq!(ImageDocument::from_json(&d.to_json().unwrap()), Err(EditorError::InvalidCrop));
    }

    #[test]
    fn json_rejects_id_zero_and_fixes_next_id() {
        let mut d = doc();
        d.add_annotation(rect_kind(0.0), Style::default()).unwrap();
        let json = d.to_json().unwrap();
        let mut v: serde_json::Value = serde_json::from_str(&json).unwrap();
        v["annotations"][0]["id"] = serde_json::json!(0);
        assert!(matches!(ImageDocument::from_json(&v.to_string()), Err(EditorError::Malformed(_))));
        let mut v: serde_json::Value = serde_json::from_str(&json).unwrap();
        v["next_id"] = serde_json::json!(0);
        assert!(ImageDocument::from_json(&v.to_string()).unwrap().next_id >= 1);
    }

    #[test]
    fn json_repairs_next_id() {
        let mut d = doc();
        d.add_annotation(rect_kind(0.0), Style::default()).unwrap();
        d.next_id = 1; // stale counter
        let back = ImageDocument::from_json(&d.to_json().unwrap()).unwrap();
        assert!(back.next_id > back.annotations[0].id.0);
    }

    #[test]
    fn json_uses_tagged_kinds() {
        let mut d = doc();
        d.add_annotation(AnnotationKind::Redact { rect: Rect::new(0.0, 0.0, 1.0, 1.0) }, Style::default()).unwrap();
        assert!(d.to_json().unwrap().contains(r#""type":"redact""#));
    }
}
