//! Editor error type.

use crate::model::AnnotationId;

/// Errors produced by editing operations and (de)serialization.
#[derive(Debug, thiserror::Error, PartialEq)]
pub enum EditorError {
    #[error("annotation {0:?} not found")]
    NotFound(AnnotationId),
    #[error("annotation id {0:?} already exists")]
    DuplicateId(AnnotationId),
    #[error("crop rectangle is empty, non-finite, or outside the image bounds")]
    InvalidCrop,
    #[error("invalid value: {0}")]
    InvalidValue(&'static str),
    #[error("edit is stale: document no longer matches the edit's `before` state")]
    Stale,
    #[error("unsupported document version {found} (this build supports up to {supported})")]
    UnsupportedVersion { found: u32, supported: u32 },
    #[error("malformed document: {0}")]
    Malformed(String),
}
