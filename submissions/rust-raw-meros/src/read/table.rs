//! [`IdTable`]: an open-addressed `i64 -> u32` table for the hot path of a batch (article id -> row, tag id -> rank).
//!
//! Why not `HashMap`: its SipHash costs more than the whole lookup is worth, and a batch builds a table per
//! statement, so the allocation matters too. Here the hash is one multiplication (Fibonacci hashing), probing is
//! linear, and the slot vector keeps its capacity from batch to batch.
//!
//! Not handled on purpose: removal, growth (the caller says how many keys it will insert, and inserting more than
//! that is refused), keys that are not ids (the hash is only good for integers that are not adversarial: these come
//! from Postgres, not from a client).

/// Marks a free slot. A stored value can never be this, see [`IdTable::insert`].
const EMPTY: u32 = u32::MAX;
/// Smallest table, so tiny batches do not thrash on tiny masks.
const MIN_SLOTS: usize = 16;
/// 2^64 / golden ratio: spreads consecutive ids over the whole hash range.
const FIBONACCI: u64 = 0x9E37_79B9_7F4A_7C15;

#[derive(Default)]
pub struct IdTable {
    slots: Vec<(i64, u32)>,
    /// Slots in use this round (a power of two, at most `slots.len()`).
    active: usize,
    len: usize,
}

impl IdTable {
    /// Empties the table and sizes it for `keys` insertions (load factor at most one half).
    pub fn reset(&mut self, keys: usize) {
        let wanted = (keys.saturating_mul(2)).next_power_of_two().max(MIN_SLOTS);
        if self.slots.len() < wanted {
            self.slots.resize(wanted, (0, EMPTY));
        }
        self.active = wanted;
        self.slots[..wanted].fill((0, EMPTY));
        self.len = 0;
    }

    #[cfg(test)]
    pub fn footprint(&self) -> usize {
        self.slots.capacity() * size_of::<(i64, u32)>()
    }

    /// Number of keys stored.
    #[cfg(test)]
    pub fn len(&self) -> usize {
        self.len
    }

    #[cfg(test)]
    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    fn home(&self, key: i64) -> usize {
        let shift = 64 - self.active.trailing_zeros();
        ((key as u64).wrapping_mul(FIBONACCI) >> shift) as usize
    }

    /// Stores `key -> value`. Returns false (and stores nothing) if the key is already there, the table is more
    /// than half full, or `value` is the reserved `u32::MAX`; the first mapping of a key wins.
    pub fn insert(&mut self, key: i64, value: u32) -> bool {
        if value == EMPTY || self.active == 0 || self.len * 2 >= self.active {
            return false;
        }
        let mask = self.active - 1;
        let mut at = self.home(key);
        loop {
            let slot = &mut self.slots[at];
            if slot.1 == EMPTY {
                *slot = (key, value);
                self.len += 1;
                return true;
            }
            if slot.0 == key {
                return false;
            }
            at = (at + 1) & mask;
        }
    }

    pub fn get(&self, key: i64) -> Option<u32> {
        if self.active == 0 {
            return None;
        }
        let mask = self.active - 1;
        let mut at = self.home(key);
        loop {
            let slot = self.slots[at];
            if slot.1 == EMPTY {
                return None;
            }
            if slot.0 == key {
                return Some(slot.1);
            }
            at = (at + 1) & mask;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_what_it_stored_and_nothing_else() {
        let mut t = IdTable::default();
        t.reset(100);
        for id in 0..100 {
            assert!(t.insert(id * 7919 + 1, id as u32));
        }
        for id in 0..100 {
            assert_eq!(t.get(id * 7919 + 1), Some(id as u32));
        }
        assert_eq!(t.get(2), None);
        assert_eq!(t.len(), 100);
    }

    #[test]
    fn first_mapping_wins_and_overfull_is_refused() {
        let mut t = IdTable::default();
        t.reset(2);
        assert!(t.insert(5, 1));
        assert!(!t.insert(5, 2));
        assert_eq!(t.get(5), Some(1));
        t.reset(1);
        let stored = (0..1000).filter(|&k| t.insert(k, 0)).count();
        assert_eq!(stored, MIN_SLOTS / 2);
    }

    #[test]
    fn reset_forgets_and_keeps_the_allocation() {
        let mut t = IdTable::default();
        t.reset(1000);
        t.insert(1, 1);
        let pointer = t.slots.as_ptr();
        t.reset(10);
        assert_eq!(t.get(1), None);
        assert!(t.is_empty());
        assert_eq!(t.slots.as_ptr(), pointer);
    }

    #[test]
    fn colliding_and_negative_keys() {
        let mut t = IdTable::default();
        t.reset(8);
        for (i, k) in [-1_i64, i64::MIN, i64::MAX, 0, 16, 32]
            .into_iter()
            .enumerate()
        {
            assert!(t.insert(k, i as u32));
        }
        assert_eq!(t.get(i64::MIN), Some(1));
        assert_eq!(t.get(32), Some(5));
    }
}
