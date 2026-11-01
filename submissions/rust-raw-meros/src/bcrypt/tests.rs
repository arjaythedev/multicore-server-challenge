//! Integration-level tests of the bcrypt module: known vectors, a reference implementation, lane equivalence,
//! the seed data, and an ignored benchmark.

use super::*;

#[path = "vectors.rs"]
mod vectors;

fn from_hex(s: &str) -> Vec<u8> {
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
        .collect()
}

/// Deterministic xorshift generator so failures reproduce.
struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn salt(&mut self) -> [u8; 16] {
        std::array::from_fn(|_| self.next() as u8)
    }
}

#[test]
fn crypt_blowfish_vectors() {
    // From the original crypt_blowfish test list.
    let cases: [(&[u8], &[u8]); 3] = [
        (
            b"U*U",
            b"$2a$05$CCCCCCCCCCCCCCCCCCCCC.E5YPO9kmyuRGyh0XouQYb4YMJKvyOeW",
        ),
        (
            b"U*U*",
            b"$2a$05$CCCCCCCCCCCCCCCCCCCCC.VGOzA784oUp/Z0DY336zx7pLYAy0lwK",
        ),
        (
            b"",
            b"$2a$05$CCCCCCCCCCCCCCCCCCCCC.7uG0VCzI2bS7j6ymqJi9CdcdxiRTWNy",
        ),
    ];
    for (password, stored) in cases {
        assert!(
            verify(password, stored),
            "{}",
            String::from_utf8_lossy(stored)
        );
        assert!(!verify(b"wrong", stored));
    }
}

#[test]
fn matches_pyca_reference_on_56_cases() {
    for (hex, stored) in vectors::REFERENCE {
        let password = from_hex(hex);
        let parsed = parse(stored.as_bytes()).unwrap();
        let rebuilt = hash(&password, parsed.salt, parsed.cost);
        // pyca writes $2b$, we write $2a$: compare everything after the prefix.
        assert_eq!(&rebuilt[4..], &stored.as_bytes()[4..], "password {hex}");
    }
}

#[test]
fn lanes_equal_single_lane_for_mixed_jobs() {
    let mut rng = Rng(0x9e3779b97f4a7c15);
    let passwords: Vec<Vec<u8>> = (0..9).map(|i| vec![b'a' + i as u8; i * 9]).collect();
    for count in 1..=9 {
        let jobs: Vec<HashJob> = (0..count)
            .map(|i| HashJob {
                password: &passwords[i],
                salt: rng.salt(),
                cost: 4 + (i % 3) as u32,
            })
            .collect();
        let together = hash_many(&jobs);
        for (job, got) in jobs.iter().zip(&together) {
            assert_eq!(hash_many(&[*job])[0], *got, "count {count}");
        }
    }
}

#[test]
fn verify_many_flags_each_item() {
    let good = hash(b"secret", [7; 16], 4);
    let items: [(&[u8], &[u8]); 4] = [
        (b"secret", &good),
        (b"nope", &good),
        (b"secret", b"not a hash"),
        (b"secret", &good),
    ];
    assert_eq!(verify_many(&items), [true, false, false, true]);
    assert!(verify_many(&[]).is_empty());
}

#[test]
fn hash_many_of_nothing_is_empty() {
    assert!(hash_many(&[]).is_empty());
}

/// `select password_hash from users order by id limit 12` on conduit_dev returned this one hash 12 times
/// (the seed gives every user the same password), so 12 copies exercise two full batches of six.
#[test]
fn seed_data_verifies_password123() {
    let seed: [&str; 12] = [SEED; 12];
    let items: Vec<(&[u8], &[u8])> = seed
        .iter()
        .map(|h| (&b"password123"[..], h.as_bytes()))
        .collect();
    assert!(verify_many(&items).iter().all(|&ok| ok));
}
const SEED: &str = "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq";

#[test]
#[ignore = "benchmark: cargo test --release -- --ignored --nocapture"]
fn bench_ms_per_hash_by_lane_count() {
    use std::time::Instant;
    let passwords = [b"password123".as_slice(); MAX_LANES];
    let mut single = 0.0;
    for lanes in 1..=MAX_LANES {
        let jobs: Vec<HashJob> = (0..lanes)
            .map(|i| HashJob {
                password: passwords[i],
                salt: [i as u8; 16],
                cost: 10,
            })
            .collect();
        let runs = 6;
        let start = Instant::now();
        for _ in 0..runs {
            std::hint::black_box(hash_many(std::hint::black_box(&jobs)));
        }
        let per_hash = start.elapsed().as_secs_f64() * 1000.0 / (runs * lanes) as f64;
        if lanes == 1 {
            single = per_hash;
        }
        println!(
            "{lanes} lanes: {per_hash:.2} ms/hash ({:.0}% of single)",
            per_hash / single * 100.0
        );
    }
}
