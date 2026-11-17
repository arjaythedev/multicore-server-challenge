//! In-memory articlesCount cache for global articles list and tag-filtered lists.
//!
//! Avoids expensive COUNT(*) / windowed count queries in PostgreSQL by maintaining
//! generation-invalidated counts. Since all article mutations flow through this
//! server process, generation counters track when counts can change.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

static CREATE_GEN: AtomicU64 = AtomicU64::new(0);
static DELETE_GEN: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Gens {
    pub create: u64,
    pub delete: u64,
}

#[derive(Clone, Copy, Debug)]
struct Entry {
    count: i64,
    create: u64,
    delete: u64,
}

impl Entry {
    #[inline]
    fn is_valid(&self, current_create: u64, current_delete: u64) -> bool {
        self.delete == current_delete && (self.count >= 1000 || self.create == current_create)
    }
}

static GLOBAL_ENTRY: Mutex<Option<Entry>> = Mutex::new(None);
static TAG_ENTRIES: Mutex<Option<HashMap<String, Entry>>> = Mutex::new(None);
static ENABLED: OnceLock<bool> = OnceLock::new();

pub fn enabled() -> bool {
    *ENABLED.get_or_init(|| {
        std::env::var("COUNT_CACHE")
            .map(|v| v != "0")
            .unwrap_or(true)
    })
}

pub fn snapshot() -> Gens {
    Gens {
        create: CREATE_GEN.load(Ordering::SeqCst),
        delete: DELETE_GEN.load(Ordering::SeqCst),
    }
}

pub fn get_global() -> Option<i64> {
    if !enabled() {
        return None;
    }
    let cur_create = CREATE_GEN.load(Ordering::SeqCst);
    let cur_delete = DELETE_GEN.load(Ordering::SeqCst);
    let guard = GLOBAL_ENTRY.lock().unwrap();
    guard.as_ref().and_then(|e| {
        if e.is_valid(cur_create, cur_delete) {
            Some(e.count)
        } else {
            None
        }
    })
}

pub fn get_tag(tag: &str) -> Option<i64> {
    if !enabled() {
        return None;
    }
    let cur_create = CREATE_GEN.load(Ordering::SeqCst);
    let cur_delete = DELETE_GEN.load(Ordering::SeqCst);
    let guard = TAG_ENTRIES.lock().unwrap();
    guard.as_ref().and_then(|map| {
        map.get(tag).and_then(|e| {
            if e.is_valid(cur_create, cur_delete) {
                Some(e.count)
            } else {
                None
            }
        })
    })
}

pub fn put_global(count: i64, at: &Gens) {
    if !enabled() {
        return;
    }
    let entry = Entry {
        count,
        create: at.create,
        delete: at.delete,
    };
    let mut guard = GLOBAL_ENTRY.lock().unwrap();
    *guard = Some(entry);
}

pub fn put_tag(tag: &str, count: i64, at: &Gens) {
    if !enabled() {
        return;
    }
    let entry = Entry {
        count,
        create: at.create,
        delete: at.delete,
    };
    let mut guard = TAG_ENTRIES.lock().unwrap();
    let map = guard.get_or_insert_with(HashMap::new);
    if map.len() >= 4096 {
        map.clear();
    }
    map.insert(tag.to_string(), entry);
}

// Rendered JSON body of GET /api/tags. Tags are only ever added (by article creates) and never
// removed, so the body stays correct for as long as no create has finished since it was read.
static TAGS_BODY: Mutex<Option<(Arc<Vec<u8>>, u64)>> = Mutex::new(None);

pub fn get_tags_body() -> Option<Arc<Vec<u8>>> {
    if !enabled() {
        return None;
    }
    let now = CREATE_GEN.load(Ordering::SeqCst);
    let guard = TAGS_BODY.lock().unwrap();
    match guard.as_ref() {
        Some((body, at)) if *at == now => Some(Arc::clone(body)),
        _ => None,
    }
}

pub fn put_tags_body(body: &[u8], at: &Gens) {
    if !enabled() {
        return;
    }
    *TAGS_BODY.lock().unwrap() = Some((Arc::new(body.to_vec()), at.create));
}

pub fn on_article_create() {
    CREATE_GEN.fetch_add(1, Ordering::SeqCst);
}

pub fn on_article_delete() {
    DELETE_GEN.fetch_add(1, Ordering::SeqCst);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_count_cache_lifecycle_and_invalidation() {
        assert!(enabled());

        // 1. Global list tests
        let snap1 = snapshot();
        put_global(5, &snap1);
        assert_eq!(get_global(), Some(5));

        // on_article_create -> None (count < 1000 is invalidated by create)
        on_article_create();
        assert_eq!(get_global(), None);

        // put_global(1000, snap2) -> on_article_create -> Some(1000)
        let snap2 = snapshot();
        put_global(1000, &snap2);
        assert_eq!(get_global(), Some(1000));
        on_article_create();
        assert_eq!(get_global(), Some(1000));

        // on_article_delete -> None (delete invalidates even 1000)
        on_article_delete();
        assert_eq!(get_global(), None);

        // put with an OLD snapshot (taken before a create) -> get returns None
        let old_snap = snapshot();
        on_article_create();
        put_global(42, &old_snap);
        assert_eq!(get_global(), None);

        // 2. Tag list tests
        let t_snap1 = snapshot();
        put_tag("rust", 5, &t_snap1);
        assert_eq!(get_tag("rust"), Some(5));
        assert_eq!(get_tag("go"), None, "different tag unaffected by put of another tag");

        put_tag("go", 10, &t_snap1);
        assert_eq!(get_tag("rust"), Some(5));
        assert_eq!(get_tag("go"), Some(10));

        // on_article_create -> None for tag count < 1000
        on_article_create();
        assert_eq!(get_tag("rust"), None);
        assert_eq!(get_tag("go"), None);

        // put_tag(1000, t_snap2) -> on_article_create -> Some(1000)
        let t_snap2 = snapshot();
        put_tag("rust", 1000, &t_snap2);
        assert_eq!(get_tag("rust"), Some(1000));
        on_article_create();
        assert_eq!(get_tag("rust"), Some(1000));

        // on_article_delete -> None
        on_article_delete();
        assert_eq!(get_tag("rust"), None);

        // put with an old snapshot for tag -> returns None
        let t_old = snapshot();
        on_article_create();
        put_tag("rust", 7, &t_old);
        assert_eq!(get_tag("rust"), None);

        // 3. Tags body: valid until the next create, unaffected by deletes, old snapshot rejected
        let b_snap = snapshot();
        put_tags_body(b"{\"tags\":[\"a\"]}", &b_snap);
        assert_eq!(get_tags_body().as_deref().map(|v| v.as_slice()), Some(&b"{\"tags\":[\"a\"]}"[..]));
        on_article_delete();
        assert!(get_tags_body().is_some());
        on_article_create();
        assert!(get_tags_body().is_none());
        put_tags_body(b"{}", &b_snap);
        assert!(get_tags_body().is_none());
    }
}
