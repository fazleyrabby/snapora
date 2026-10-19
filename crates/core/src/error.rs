use thiserror::Error;

/// Errors returned by core operations. Messages must never contain capture
/// content (pixels, recognized text, window titles).
#[derive(Debug, Clone, PartialEq, Error)]
pub enum CoreError {
    #[error("rectangle has non-finite or negative dimensions")]
    InvalidRect,
    #[error("selection is empty")]
    EmptySelection,
    #[error("selection does not intersect the display")]
    OutsideDisplay,
    #[error("display scale factor must be positive")]
    InvalidScale,
}
