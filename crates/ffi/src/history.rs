//! History surface: `HistoryDb` over `snapora_history::HistoryStore`.

use std::path::Path;
use std::sync::{Mutex, MutexGuard};

use snapora_history as h;

use crate::SnaporaError;

impl From<h::HistoryError> for SnaporaError {
    fn from(e: h::HistoryError) -> Self {
        SnaporaError::History { message: e.to_string() }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CaptureKind {
    Screenshot,
    Recording,
    Gif,
    Scrolling,
}

impl From<CaptureKind> for h::CaptureKind {
    fn from(k: CaptureKind) -> Self {
        match k {
            CaptureKind::Screenshot => Self::Screenshot,
            CaptureKind::Recording => Self::Recording,
            CaptureKind::Gif => Self::Gif,
            CaptureKind::Scrolling => Self::Scrolling,
        }
    }
}

impl From<h::CaptureKind> for CaptureKind {
    fn from(k: h::CaptureKind) -> Self {
        match k {
            h::CaptureKind::Screenshot => Self::Screenshot,
            h::CaptureKind::Recording => Self::Recording,
            h::CaptureKind::Gif => Self::Gif,
            h::CaptureKind::Scrolling => Self::Scrolling,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct CaptureRecord {
    pub id: i64,
    pub kind: CaptureKind,
    pub file_path: String,
    pub thumbnail_path: Option<String>,
    pub width: u32,
    pub height: u32,
    pub duration_ms: Option<u64>,
    /// Unix seconds.
    pub created_at: i64,
    pub favorite: bool,
    pub title: Option<String>,
    pub ocr_text: Option<String>,
}

impl From<h::CaptureRecord> for CaptureRecord {
    fn from(r: h::CaptureRecord) -> Self {
        CaptureRecord {
            id: r.id,
            kind: r.kind.into(),
            file_path: r.file_path,
            thumbnail_path: r.thumbnail_path,
            width: r.width,
            height: r.height,
            duration_ms: r.duration_ms,
            created_at: r.created_at,
            favorite: r.favorite,
            title: r.title,
            ocr_text: r.ocr_text,
        }
    }
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct NewCaptureRecord {
    pub kind: CaptureKind,
    pub file_path: String,
    pub thumbnail_path: Option<String>,
    pub width: u32,
    pub height: u32,
    pub duration_ms: Option<u64>,
    /// Unix seconds.
    pub created_at: i64,
    pub title: Option<String>,
    pub ocr_text: Option<String>,
}

impl From<NewCaptureRecord> for h::NewCapture {
    fn from(n: NewCaptureRecord) -> Self {
        h::NewCapture {
            kind: n.kind.into(),
            file_path: n.file_path,
            thumbnail_path: n.thumbnail_path,
            width: n.width,
            height: n.height,
            duration_ms: n.duration_ms,
            created_at: n.created_at,
            title: n.title,
            ocr_text: n.ocr_text,
        }
    }
}

#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct HistoryQuery {
    #[uniffi(default = None)]
    pub kind: Option<CaptureKind>,
    #[uniffi(default = false)]
    pub favorites_only: bool,
    #[uniffi(default = None)]
    pub search: Option<String>,
    #[uniffi(default = None)]
    pub limit: Option<u32>,
    #[uniffi(default = 0)]
    pub offset: u32,
}

impl From<HistoryQuery> for h::ListQuery {
    fn from(q: HistoryQuery) -> Self {
        h::ListQuery {
            kind: q.kind.map(Into::into),
            favorites_only: q.favorites_only,
            search: q.search,
            limit: q.limit,
            offset: q.offset,
        }
    }
}

#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct HistoryRetentionPolicy {
    pub max_age_days: Option<u32>,
    pub max_items: Option<u32>,
    pub keep_favorites: bool,
}

impl From<HistoryRetentionPolicy> for h::RetentionPolicy {
    fn from(p: HistoryRetentionPolicy) -> Self {
        h::RetentionPolicy {
            max_age_days: p.max_age_days,
            max_items: p.max_items,
            keep_favorites: p.keep_favorites,
        }
    }
}

/// SQLite-backed capture history.
#[derive(uniffi::Object)]
pub struct HistoryDb {
    inner: Mutex<h::HistoryStore>,
}

impl HistoryDb {
    fn store(&self) -> MutexGuard<'_, h::HistoryStore> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }
}

#[uniffi::export]
impl HistoryDb {
    #[uniffi::constructor]
    pub fn open(path: String) -> Result<Self, SnaporaError> {
        Ok(Self { inner: Mutex::new(h::HistoryStore::open(path)?) })
    }

    pub fn insert(&self, record: NewCaptureRecord) -> Result<i64, SnaporaError> {
        Ok(self.store().insert(record.into())?)
    }

    pub fn get(&self, id: i64) -> Result<Option<CaptureRecord>, SnaporaError> {
        Ok(self.store().get(id)?.map(Into::into))
    }

    pub fn list(&self, query: HistoryQuery) -> Result<Vec<CaptureRecord>, SnaporaError> {
        Ok(self.store().list(&query.into())?.into_iter().map(Into::into).collect())
    }

    pub fn count(&self) -> Result<u64, SnaporaError> {
        Ok(self.store().count()?)
    }

    /// Returns whether a row was deleted.
    pub fn delete(&self, id: i64) -> Result<bool, SnaporaError> {
        Ok(self.store().delete(id)?)
    }

    pub fn set_favorite(&self, id: i64, favorite: bool) -> Result<(), SnaporaError> {
        Ok(self.store().set_favorite(id, favorite)?)
    }

    pub fn set_thumbnail(&self, id: i64, path: Option<String>) -> Result<(), SnaporaError> {
        Ok(self.store().set_thumbnail(id, path.as_deref())?)
    }

    pub fn set_ocr_text(&self, id: i64, text: Option<String>) -> Result<(), SnaporaError> {
        Ok(self.store().set_ocr_text(id, text.as_deref())?)
    }

    pub fn set_title(&self, id: i64, title: Option<String>) -> Result<(), SnaporaError> {
        Ok(self.store().set_title(id, title.as_deref())?)
    }

    /// Removes rows whose media file no longer exists; returns removed ids.
    pub fn prune_missing(&self) -> Result<Vec<i64>, SnaporaError> {
        Ok(self.store().prune_missing(|p| Path::new(p).exists())?)
    }

    /// Deletes rows beyond the policy; returns them so the caller can remove files.
    pub fn apply_retention(
        &self,
        policy: HistoryRetentionPolicy,
        now_unix: i64,
    ) -> Result<Vec<CaptureRecord>, SnaporaError> {
        Ok(self
            .store()
            .apply_retention(&policy.into(), now_unix)?
            .into_iter()
            .map(Into::into)
            .collect())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn new_rec(path: &str, at: i64) -> NewCaptureRecord {
        NewCaptureRecord {
            kind: CaptureKind::Gif,
            file_path: path.into(),
            thumbnail_path: None,
            width: 10,
            height: 20,
            duration_ms: Some(1500),
            created_at: at,
            title: None,
            ocr_text: None,
        }
    }

    #[test]
    fn insert_list_favorite_prune_retention() {
        let dir = tempfile::tempdir().unwrap();
        let real = dir.path().join("real.gif");
        std::fs::write(&real, b"x").unwrap();
        let db = HistoryDb::open(dir.path().join("h.sqlite").to_string_lossy().into_owned()).unwrap();

        let a = db.insert(new_rec(real.to_str().unwrap(), 100)).unwrap();
        let b = db.insert(new_rec("/nonexistent/gone.gif", 200)).unwrap();
        assert_eq!(db.count().unwrap(), 2);
        let all = db.list(HistoryQuery::default()).unwrap();
        assert_eq!(all[0].id, b);
        assert_eq!(all[0].kind, CaptureKind::Gif);
        assert_eq!(all[0].duration_ms, Some(1500));

        db.set_favorite(a, true).unwrap();
        let favs = db.list(HistoryQuery { favorites_only: true, ..Default::default() }).unwrap();
        assert_eq!(favs.len(), 1);
        assert!(matches!(db.set_title(999, None), Err(SnaporaError::History { .. })));

        assert_eq!(db.prune_missing().unwrap(), vec![b]);
        let doomed = db
            .apply_retention(
                HistoryRetentionPolicy { max_age_days: Some(1), max_items: None, keep_favorites: true },
                10_000_000,
            )
            .unwrap();
        assert!(doomed.is_empty());
        assert_eq!(db.count().unwrap(), 1);
    }
}
