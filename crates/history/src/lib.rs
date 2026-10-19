//! Local capture history stored in SQLite.
//!
//! Only metadata lives in the database; media files stay on disk. The store
//! never logs titles or OCR text, only ids and counts.

use std::path::Path;

use rusqlite::{Connection, OptionalExtension, Row, params, params_from_iter, types::Value};

/// Ordered schema migrations. Index `i` upgrades `user_version` `i` -> `i + 1`.
/// Append a new entry to add v2; never edit existing ones.
const MIGRATIONS: &[&str] = &[
    // v1
    "CREATE TABLE captures (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        kind           TEXT    NOT NULL,
        file_path      TEXT    NOT NULL,
        file_name      TEXT    NOT NULL,
        thumbnail_path TEXT,
        width          INTEGER NOT NULL,
        height         INTEGER NOT NULL,
        duration_ms    INTEGER,
        created_at     INTEGER NOT NULL,
        favorite       INTEGER NOT NULL DEFAULT 0,
        title          TEXT,
        ocr_text       TEXT
    );
    CREATE INDEX idx_captures_created ON captures(created_at DESC, id DESC);
    CREATE INDEX idx_captures_kind ON captures(kind);",
];

const SECS_PER_DAY: i64 = 86_400;

#[derive(Debug, thiserror::Error)]
pub enum HistoryError {
    #[error("database error: {0}")]
    Database(#[from] rusqlite::Error),
    #[error("database schema version {found} is newer than supported version {supported}")]
    SchemaTooNew { found: u32, supported: u32 },
    #[error("invalid capture kind in database: {0}")]
    InvalidKind(String),
    #[error("capture {0} not found")]
    NotFound(i64),
}

pub type Result<T> = std::result::Result<T, HistoryError>;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CaptureKind {
    Screenshot,
    Recording,
    Gif,
    Scrolling,
}

impl CaptureKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Screenshot => "screenshot",
            Self::Recording => "recording",
            Self::Gif => "gif",
            Self::Scrolling => "scrolling",
        }
    }

    pub fn parse(s: &str) -> Result<Self> {
        match s {
            "screenshot" => Ok(Self::Screenshot),
            "recording" => Ok(Self::Recording),
            "gif" => Ok(Self::Gif),
            "scrolling" => Ok(Self::Scrolling),
            other => Err(HistoryError::InvalidKind(other.to_string())),
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
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

#[derive(Debug, Clone, PartialEq)]
pub struct NewCapture {
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

impl NewCapture {
    pub fn new(
        kind: CaptureKind,
        file_path: impl Into<String>,
        width: u32,
        height: u32,
        created_at: i64,
    ) -> Self {
        Self {
            kind,
            file_path: file_path.into(),
            thumbnail_path: None,
            width,
            height,
            duration_ms: None,
            created_at,
            title: None,
            ocr_text: None,
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct ListQuery {
    pub kind: Option<CaptureKind>,
    pub favorites_only: bool,
    /// Case-insensitive substring match on title, file name and OCR text.
    pub search: Option<String>,
    pub limit: Option<u32>,
    pub offset: u32,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct RetentionPolicy {
    pub max_age_days: Option<u32>,
    pub max_items: Option<u32>,
    /// Favorites are never deleted and do not count toward `max_items`.
    pub keep_favorites: bool,
}

pub struct HistoryStore {
    conn: Connection,
}

impl HistoryStore {
    pub fn open(path: impl AsRef<Path>) -> Result<Self> {
        let conn = Connection::open(path)?;
        // `journal_mode` returns a row, so read it back.
        let _mode: String = conn.query_row("PRAGMA journal_mode = WAL", [], |r| r.get(0))?;
        Self::init(conn)
    }

    pub fn open_in_memory() -> Result<Self> {
        Self::init(Connection::open_in_memory()?)
    }

    fn init(conn: Connection) -> Result<Self> {
        conn.busy_timeout(std::time::Duration::from_secs(5))?;
        let mut store = Self { conn };
        store.migrate()?;
        Ok(store)
    }

    fn migrate(&mut self) -> Result<()> {
        let current: u32 = self.conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        let supported = MIGRATIONS.len() as u32;
        if current > supported {
            return Err(HistoryError::SchemaTooNew { found: current, supported });
        }
        for (i, sql) in MIGRATIONS.iter().enumerate().skip(current as usize) {
            let tx = self.conn.transaction()?;
            tx.execute_batch(sql)?;
            tx.pragma_update(None, "user_version", i as u32 + 1)?;
            tx.commit()?;
            tracing::info!(version = i + 1, "history schema migrated");
        }
        Ok(())
    }

    /// Current schema version (`PRAGMA user_version`).
    pub fn schema_version(&self) -> Result<u32> {
        Ok(self.conn.query_row("PRAGMA user_version", [], |r| r.get(0))?)
    }

    pub fn insert(&self, new: NewCapture) -> Result<i64> {
        self.conn.execute(
            "INSERT INTO captures (kind, file_path, file_name, thumbnail_path, width, height,
                                   duration_ms, created_at, favorite, title, ocr_text)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 0, ?9, ?10)",
            params![
                new.kind.as_str(),
                new.file_path,
                file_name_of(&new.file_path),
                new.thumbnail_path,
                new.width,
                new.height,
                new.duration_ms.map(|d| d as i64),
                new.created_at,
                new.title,
                new.ocr_text,
            ],
        )?;
        let id = self.conn.last_insert_rowid();
        tracing::debug!(id, "history record inserted");
        Ok(id)
    }

    pub fn get(&self, id: i64) -> Result<Option<CaptureRecord>> {
        self.conn
            .query_row(
                &format!("SELECT {COLUMNS} FROM captures WHERE id = ?1"),
                [id],
                row_to_record,
            )
            .optional()?
            .transpose()
    }

    pub fn list(&self, query: &ListQuery) -> Result<Vec<CaptureRecord>> {
        let mut sql = format!("SELECT {COLUMNS} FROM captures WHERE 1=1");
        let mut args: Vec<Value> = Vec::new();
        if let Some(kind) = query.kind {
            args.push(Value::Text(kind.as_str().into()));
            sql.push_str(&format!(" AND kind = ?{}", args.len()));
        }
        if query.favorites_only {
            sql.push_str(" AND favorite = 1");
        }
        if let Some(search) = query.search.as_deref().filter(|s| !s.is_empty()) {
            args.push(Value::Text(format!("%{}%", escape_like(search))));
            let n = args.len();
            sql.push_str(&format!(
                " AND (title LIKE ?{n} ESCAPE '\\' OR file_name LIKE ?{n} ESCAPE '\\' \
                 OR ocr_text LIKE ?{n} ESCAPE '\\')"
            ));
        }
        sql.push_str(" ORDER BY created_at DESC, id DESC");
        // SQLite requires LIMIT before OFFSET; -1 means unlimited.
        let limit = query.limit.map_or(-1, i64::from);
        sql.push_str(&format!(" LIMIT {limit} OFFSET {}", query.offset));

        let mut stmt = self.conn.prepare(&sql)?;
        let rows = stmt.query_map(params_from_iter(args), row_to_record)?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r??);
        }
        Ok(out)
    }

    pub fn count(&self) -> Result<u64> {
        let n: i64 = self.conn.query_row("SELECT COUNT(*) FROM captures", [], |r| r.get(0))?;
        Ok(n as u64)
    }

    pub fn set_favorite(&self, id: i64, favorite: bool) -> Result<()> {
        self.update_one("UPDATE captures SET favorite = ?1 WHERE id = ?2", params![favorite, id], id)
    }

    pub fn set_thumbnail(&self, id: i64, path: Option<&str>) -> Result<()> {
        self.update_one(
            "UPDATE captures SET thumbnail_path = ?1 WHERE id = ?2",
            params![path, id],
            id,
        )
    }

    pub fn set_ocr_text(&self, id: i64, text: Option<&str>) -> Result<()> {
        self.update_one("UPDATE captures SET ocr_text = ?1 WHERE id = ?2", params![text, id], id)
    }

    pub fn set_title(&self, id: i64, title: Option<&str>) -> Result<()> {
        self.update_one("UPDATE captures SET title = ?1 WHERE id = ?2", params![title, id], id)
    }

    fn update_one(&self, sql: &str, p: impl rusqlite::Params, id: i64) -> Result<()> {
        if self.conn.execute(sql, p)? == 0 {
            return Err(HistoryError::NotFound(id));
        }
        Ok(())
    }

    /// Deletes the record. Returns whether a row existed.
    pub fn delete(&self, id: i64) -> Result<bool> {
        let n = self.conn.execute("DELETE FROM captures WHERE id = ?1", [id])?;
        Ok(n > 0)
    }

    /// Removes records whose media file no longer exists according to
    /// `exists`, returning the removed ids (ascending).
    pub fn prune_missing(&mut self, exists: impl Fn(&str) -> bool) -> Result<Vec<i64>> {
        let tx = self.conn.transaction()?;
        let candidates: Vec<(i64, String)> = {
            let mut stmt = tx.prepare("SELECT id, file_path FROM captures ORDER BY id")?;
            stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
                .collect::<rusqlite::Result<_>>()?
        };
        let mut removed = Vec::new();
        for (id, path) in candidates {
            if !exists(&path) {
                tx.execute("DELETE FROM captures WHERE id = ?1", [id])?;
                removed.push(id);
            }
        }
        tx.commit()?;
        tracing::info!(count = removed.len(), "history pruned missing media");
        Ok(removed)
    }

    /// Deletes records expired by `policy` as of `now` (unix seconds) and
    /// returns them (oldest first) so the caller can delete their files.
    ///
    /// Age is applied first, then `max_items` keeps the newest N of the
    /// remaining deletable records.
    pub fn apply_retention(
        &mut self,
        policy: &RetentionPolicy,
        now: i64,
    ) -> Result<Vec<CaptureRecord>> {
        let tx = self.conn.transaction()?;
        let protect = if policy.keep_favorites { "AND favorite = 0" } else { "" };
        let mut doomed: Vec<CaptureRecord> = Vec::new();

        if let Some(days) = policy.max_age_days {
            let cutoff = now.saturating_sub(i64::from(days) * SECS_PER_DAY);
            let mut stmt = tx.prepare(&format!(
                "SELECT {COLUMNS} FROM captures WHERE created_at < ?1 {protect}
                 ORDER BY created_at ASC, id ASC"
            ))?;
            for r in stmt.query_map([cutoff], row_to_record)? {
                doomed.push(r??);
            }
        }
        let mut doomed_ids: Vec<i64> = doomed.iter().map(|r| r.id).collect();

        if let Some(max) = policy.max_items {
            let mut stmt = tx.prepare(&format!(
                "SELECT {COLUMNS} FROM captures WHERE 1=1 {protect}
                 ORDER BY created_at DESC, id DESC"
            ))?;
            let mut kept = 0u32;
            let mut extra = Vec::new();
            for r in stmt.query_map([], row_to_record)? {
                let rec = r??;
                if doomed_ids.contains(&rec.id) {
                    continue;
                }
                if kept < max {
                    kept += 1;
                } else {
                    extra.push(rec);
                }
            }
            drop(stmt);
            doomed_ids.extend(extra.iter().map(|r| r.id));
            doomed.extend(extra);
        }

        for id in &doomed_ids {
            tx.execute("DELETE FROM captures WHERE id = ?1", [id])?;
        }
        tx.commit()?;
        doomed.sort_by_key(|r| (r.created_at, r.id));
        tracing::info!(count = doomed.len(), "history retention applied");
        Ok(doomed)
    }
}

const COLUMNS: &str = "id, kind, file_path, thumbnail_path, width, height, duration_ms, \
                       created_at, favorite, title, ocr_text";

fn row_to_record(row: &Row<'_>) -> rusqlite::Result<Result<CaptureRecord>> {
    let kind: String = row.get(1)?;
    let duration: Option<i64> = row.get(6)?;
    let kind = match CaptureKind::parse(&kind) {
        Ok(k) => k,
        Err(e) => return Ok(Err(e)),
    };
    Ok(Ok(CaptureRecord {
        id: row.get(0)?,
        kind,
        file_path: row.get(2)?,
        thumbnail_path: row.get(3)?,
        width: row.get(4)?,
        height: row.get(5)?,
        duration_ms: duration.map(|d| d as u64),
        created_at: row.get(7)?,
        favorite: row.get(8)?,
        title: row.get(9)?,
        ocr_text: row.get(10)?,
    }))
}

fn file_name_of(path: &str) -> &str {
    path.rsplit(['/', '\\']).next().unwrap_or(path)
}

/// Escapes `%`, `_` and the escape char `\` for use with `LIKE ... ESCAPE '\'`.
fn escape_like(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        if matches!(c, '%' | '_' | '\\') {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> HistoryStore {
        HistoryStore::open_in_memory().unwrap()
    }

    fn add(s: &HistoryStore, name: &str, at: i64) -> i64 {
        s.insert(NewCapture::new(CaptureKind::Screenshot, format!("/caps/{name}"), 10, 20, at))
            .unwrap()
    }

    fn ids(v: &[CaptureRecord]) -> Vec<i64> {
        v.iter().map(|r| r.id).collect()
    }

    #[test]
    fn migration_on_fresh_file_db_and_reopen() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("h.db");
        let id;
        {
            let s = HistoryStore::open(&path).unwrap();
            assert_eq!(s.schema_version().unwrap(), MIGRATIONS.len() as u32);
            let mode: String =
                s.conn.query_row("PRAGMA journal_mode", [], |r| r.get(0)).unwrap();
            assert_eq!(mode, "wal");
            id = add(&s, "a.png", 5);
        }
        let s = HistoryStore::open(&path).unwrap();
        assert_eq!(s.schema_version().unwrap(), 1);
        assert_eq!(s.get(id).unwrap().unwrap().file_path, "/caps/a.png");
    }

    #[test]
    fn rejects_newer_schema() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("h.db");
        {
            let c = Connection::open(&path).unwrap();
            c.pragma_update(None, "user_version", 99).unwrap();
        }
        assert!(matches!(
            HistoryStore::open(&path),
            Err(HistoryError::SchemaTooNew { found: 99, .. })
        ));
    }

    #[test]
    fn insert_get_roundtrip() {
        let s = store();
        let mut n = NewCapture::new(CaptureKind::Recording, "/x/rec.mov", 1920, 1080, 100);
        n.duration_ms = Some(4500);
        n.thumbnail_path = Some("/t/rec.jpg".into());
        n.title = Some("Demo".into());
        n.ocr_text = Some("hello".into());
        let id = s.insert(n).unwrap();
        let r = s.get(id).unwrap().unwrap();
        assert_eq!(r.kind, CaptureKind::Recording);
        assert_eq!((r.width, r.height), (1920, 1080));
        assert_eq!(r.duration_ms, Some(4500));
        assert_eq!(r.thumbnail_path.as_deref(), Some("/t/rec.jpg"));
        assert_eq!(r.title.as_deref(), Some("Demo"));
        assert_eq!(r.ocr_text.as_deref(), Some("hello"));
        assert!(!r.favorite);
        assert_eq!(r.created_at, 100);
        assert!(s.get(id + 1).unwrap().is_none());
    }

    #[test]
    fn kinds_roundtrip() {
        let s = store();
        for k in [
            CaptureKind::Screenshot,
            CaptureKind::Recording,
            CaptureKind::Gif,
            CaptureKind::Scrolling,
        ] {
            let id = s.insert(NewCapture::new(k, "/a", 1, 1, 1)).unwrap();
            assert_eq!(s.get(id).unwrap().unwrap().kind, k);
            assert_eq!(CaptureKind::parse(k.as_str()).unwrap(), k);
        }
        assert!(CaptureKind::parse("bogus").is_err());
    }

    #[test]
    fn list_newest_first_with_paging() {
        let s = store();
        let a = add(&s, "a", 1);
        let b = add(&s, "b", 3);
        let c = add(&s, "c", 2);
        let all = s.list(&ListQuery::default()).unwrap();
        assert_eq!(ids(&all), vec![b, c, a]);
        let page = s
            .list(&ListQuery { limit: Some(1), offset: 1, ..Default::default() })
            .unwrap();
        assert_eq!(ids(&page), vec![c]);
        let offset_only = s.list(&ListQuery { offset: 2, ..Default::default() }).unwrap();
        assert_eq!(ids(&offset_only), vec![a]);
    }

    #[test]
    fn list_ties_broken_by_id_desc() {
        let s = store();
        let a = add(&s, "a", 7);
        let b = add(&s, "b", 7);
        assert_eq!(ids(&s.list(&ListQuery::default()).unwrap()), vec![b, a]);
    }

    #[test]
    fn list_filters_kind_and_favorites() {
        let s = store();
        let a = add(&s, "a", 1);
        let g = s.insert(NewCapture::new(CaptureKind::Gif, "/g.gif", 1, 1, 2)).unwrap();
        s.set_favorite(g, true).unwrap();
        let q = ListQuery { kind: Some(CaptureKind::Gif), ..Default::default() };
        assert_eq!(ids(&s.list(&q).unwrap()), vec![g]);
        let q = ListQuery { favorites_only: true, ..Default::default() };
        assert_eq!(ids(&s.list(&q).unwrap()), vec![g]);
        let q = ListQuery { kind: Some(CaptureKind::Screenshot), favorites_only: true, ..Default::default() };
        assert!(s.list(&q).unwrap().is_empty());
        let q = ListQuery { kind: Some(CaptureKind::Screenshot), ..Default::default() };
        assert_eq!(ids(&s.list(&q).unwrap()), vec![a]);
    }

    #[test]
    fn search_matches_title_filename_ocr_case_insensitive() {
        let s = store();
        let a = add(&s, "Invoice-2026.png", 1);
        let b = add(&s, "b.png", 2);
        let c = add(&s, "c.png", 3);
        s.set_title(b, Some("Quarterly REPORT")).unwrap();
        s.set_ocr_text(c, Some("total due: 42")).unwrap();
        let q = |t: &str| ListQuery { search: Some(t.into()), ..Default::default() };
        assert_eq!(ids(&s.list(&q("invoice")).unwrap()), vec![a]);
        assert_eq!(ids(&s.list(&q("report")).unwrap()), vec![b]);
        assert_eq!(ids(&s.list(&q("TOTAL")).unwrap()), vec![c]);
        assert!(s.list(&q("nomatch")).unwrap().is_empty());
        // Directory part of the path is not searched.
        assert!(s.list(&q("caps")).unwrap().is_empty());
        // Empty search means no filter.
        assert_eq!(s.list(&q("")).unwrap().len(), 3);
    }

    #[test]
    fn search_escapes_wildcards() {
        let s = store();
        let pct = add(&s, "100%.png", 1);
        let under = add(&s, "a_b.png", 2);
        let plain = add(&s, "axb.png", 3);
        let bs = add(&s, "z.png", 4);
        s.set_title(bs, Some("c\\d")).unwrap();
        let q = |t: &str| ListQuery { search: Some(t.into()), ..Default::default() };
        assert_eq!(ids(&s.list(&q("%")).unwrap()), vec![pct]);
        assert_eq!(ids(&s.list(&q("a_b")).unwrap()), vec![under]);
        assert_eq!(ids(&s.list(&q("\\")).unwrap()), vec![bs]);
        let _ = plain;
    }

    #[test]
    fn search_combined_with_kind_filter() {
        let s = store();
        add(&s, "shot-demo.png", 1);
        let g = s.insert(NewCapture::new(CaptureKind::Gif, "/demo.gif", 1, 1, 2)).unwrap();
        let q = ListQuery {
            kind: Some(CaptureKind::Gif),
            search: Some("demo".into()),
            ..Default::default()
        };
        assert_eq!(ids(&s.list(&q).unwrap()), vec![g]);
    }

    #[test]
    fn setters_and_not_found() {
        let s = store();
        let id = add(&s, "a", 1);
        s.set_favorite(id, true).unwrap();
        s.set_thumbnail(id, Some("/t.jpg")).unwrap();
        s.set_title(id, Some("T")).unwrap();
        s.set_ocr_text(id, Some("O")).unwrap();
        let r = s.get(id).unwrap().unwrap();
        assert!(r.favorite);
        assert_eq!(r.thumbnail_path.as_deref(), Some("/t.jpg"));
        assert_eq!(r.title.as_deref(), Some("T"));
        assert_eq!(r.ocr_text.as_deref(), Some("O"));
        s.set_title(id, None).unwrap();
        assert!(s.get(id).unwrap().unwrap().title.is_none());
        assert!(matches!(s.set_favorite(999, true), Err(HistoryError::NotFound(999))));
        assert!(matches!(s.set_title(999, None), Err(HistoryError::NotFound(999))));
    }

    #[test]
    fn delete_and_count() {
        let s = store();
        let a = add(&s, "a", 1);
        add(&s, "b", 2);
        assert_eq!(s.count().unwrap(), 2);
        assert!(s.delete(a).unwrap());
        assert!(!s.delete(a).unwrap());
        assert_eq!(s.count().unwrap(), 1);
    }

    #[test]
    fn prune_missing_removes_only_missing() {
        let mut s = store();
        let a = add(&s, "keep.png", 1);
        let b = add(&s, "gone.png", 2);
        let c = add(&s, "gone2.png", 3);
        let removed = s.prune_missing(|p| p.ends_with("keep.png")).unwrap();
        assert_eq!(removed, vec![b, c]);
        assert_eq!(ids(&s.list(&ListQuery::default()).unwrap()), vec![a]);
        assert!(s.prune_missing(|_| true).unwrap().is_empty());
    }

    #[test]
    fn prune_missing_with_real_files() {
        let dir = tempfile::tempdir().unwrap();
        let present = dir.path().join("p.png");
        std::fs::write(&present, b"x").unwrap();
        let mut s = store();
        let p = s
            .insert(NewCapture::new(CaptureKind::Screenshot, present.to_str().unwrap(), 1, 1, 1))
            .unwrap();
        s.insert(NewCapture::new(
            CaptureKind::Screenshot,
            dir.path().join("nope.png").to_str().unwrap(),
            1,
            1,
            2,
        ))
        .unwrap();
        s.prune_missing(|f| Path::new(f).exists()).unwrap();
        assert_eq!(ids(&s.list(&ListQuery::default()).unwrap()), vec![p]);
    }

    const DAY: i64 = SECS_PER_DAY;

    #[test]
    fn retention_by_age_returns_oldest_first() {
        let mut s = store();
        let now = 100 * DAY;
        let new = add(&s, "new", now - DAY);
        let older = add(&s, "older", now - 40 * DAY);
        let oldest = add(&s, "oldest", now - 50 * DAY);
        let p = RetentionPolicy { max_age_days: Some(30), ..Default::default() };
        let removed = s.apply_retention(&p, now).unwrap();
        assert_eq!(ids(&removed), vec![oldest, older]);
        assert_eq!(ids(&s.list(&ListQuery::default()).unwrap()), vec![new]);
    }

    #[test]
    fn retention_age_boundary_is_kept() {
        let mut s = store();
        let now = 100 * DAY;
        let edge = add(&s, "edge", now - 30 * DAY);
        let p = RetentionPolicy { max_age_days: Some(30), ..Default::default() };
        assert!(s.apply_retention(&p, now).unwrap().is_empty());
        assert!(s.get(edge).unwrap().is_some());
    }

    #[test]
    fn retention_by_count_keeps_newest() {
        let mut s = store();
        let a = add(&s, "a", 1);
        let b = add(&s, "b", 2);
        let c = add(&s, "c", 3);
        let d = add(&s, "d", 4);
        let p = RetentionPolicy { max_items: Some(2), ..Default::default() };
        let removed = s.apply_retention(&p, 10).unwrap();
        assert_eq!(ids(&removed), vec![a, b]);
        assert_eq!(ids(&s.list(&ListQuery::default()).unwrap()), vec![d, c]);
    }

    #[test]
    fn retention_favorites_protected() {
        let mut s = store();
        let now = 100 * DAY;
        let fav_old = add(&s, "fav", now - 90 * DAY);
        let old = add(&s, "old", now - 80 * DAY);
        let n1 = add(&s, "n1", now - 2);
        let n2 = add(&s, "n2", now - 1);
        s.set_favorite(fav_old, true).unwrap();
        let p = RetentionPolicy {
            max_age_days: Some(30),
            max_items: Some(1),
            keep_favorites: true,
        };
        let removed = s.apply_retention(&p, now).unwrap();
        assert_eq!(ids(&removed), vec![old, n1]);
        let left = ids(&s.list(&ListQuery::default()).unwrap());
        assert_eq!(left, vec![n2, fav_old]);
    }

    #[test]
    fn retention_favorites_not_protected_when_disabled() {
        let mut s = store();
        let now = 100 * DAY;
        let fav_old = add(&s, "fav", now - 90 * DAY);
        s.set_favorite(fav_old, true).unwrap();
        let p = RetentionPolicy { max_age_days: Some(30), ..Default::default() };
        assert_eq!(ids(&s.apply_retention(&p, now).unwrap()), vec![fav_old]);
    }

    #[test]
    fn retention_combined_does_not_double_count() {
        let mut s = store();
        let now = 100 * DAY;
        let old = add(&s, "old", now - 60 * DAY);
        let a = add(&s, "a", now - 3);
        let b = add(&s, "b", now - 2);
        let p = RetentionPolicy {
            max_age_days: Some(30),
            max_items: Some(2),
            keep_favorites: false,
        };
        // Age removes `old`; the remaining two fit within max_items.
        let removed = s.apply_retention(&p, now).unwrap();
        assert_eq!(ids(&removed), vec![old]);
        assert_eq!(ids(&s.list(&ListQuery::default()).unwrap()), vec![b, a]);
    }

    #[test]
    fn retention_empty_policy_is_noop() {
        let mut s = store();
        add(&s, "a", 1);
        assert!(s.apply_retention(&RetentionPolicy::default(), 1_000_000).unwrap().is_empty());
        assert_eq!(s.count().unwrap(), 1);
    }
}
