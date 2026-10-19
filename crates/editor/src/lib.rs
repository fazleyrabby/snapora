//! Platform-neutral image document model with undo/redo.
//!
//! This crate holds data and editing logic only; pixels are rendered by the
//! host UI (CoreGraphics on macOS). All coordinates are image pixels with a
//! top-left origin.
//!
//! # Redaction
//!
//! `Redact`, `Blur` and `Pixelate` annotations are destructive: the renderer
//! **must** bake them into exported pixels (never export them as a removable
//! vector layer). [`ImageDocument::destructive_regions`] lists them so an
//! exporter can verify that every such region was applied.

mod document;
mod error;
mod model;

pub use document::{Edit, ImageDocument, DOCUMENT_VERSION, MAX_HISTORY};
pub use error::EditorError;
pub use model::{Annotation, AnnotationId, AnnotationKind, Color, Point, Rect, Style};
