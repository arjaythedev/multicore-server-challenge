//! bcrypt ($2b$, cost 10) that smarm can preempt.
//!
//! The `bcrypt` crate's core is a 2^cost loop of Blowfish key expansions that never allocates,
//! so smarm's allocation-counted preemption never fires inside it: one verify pins a scheduler
//! thread for ~60 ms. This is the same algorithm (core vendored from bcrypt 0.17, on the same
//! `blowfish` crate) with `smarm::check!()` in the cost loop, so it runs inline in the request
//! actor and yields like any other code. Hashes are byte-compatible with the crate (tested).

use base64::alphabet::BCRYPT;
use base64::engine::general_purpose::NO_PAD;
use base64::engine::GeneralPurpose;
use base64::Engine as _;
use blowfish::Blowfish;

const B64: GeneralPurpose = GeneralPurpose::new(&BCRYPT, NO_PAD);
pub const COST: u32 = 10;

fn raw(cost: u32, salt: &[u8; 16], password: &[u8]) -> [u8; 24] {
    let mut state = Blowfish::bc_init_state();
    state.salted_expand_key(salt, password);
    for _ in 0..1u32 << cost {
        state.bc_expand_key(password);
        state.bc_expand_key(salt);
        smarm::check!();
    }
    // "OrpheanBeholderScryDoubt"
    let mut ctext = [0x4f727068u32, 0x65616e42, 0x65686f6c, 0x64657253, 0x63727944, 0x6f756274];
    let mut out = [0u8; 24];
    for i in (0..6).step_by(2) {
        for _ in 0..64 {
            let [l, r] = state.bc_encrypt([ctext[i], ctext[i + 1]]);
            ctext[i] = l;
            ctext[i + 1] = r;
        }
        out[i * 4..i * 4 + 4].copy_from_slice(&ctext[i].to_be_bytes());
        out[(i + 1) * 4..(i + 1) * 4 + 4].copy_from_slice(&ctext[i + 1].to_be_bytes());
    }
    out
}

/// NUL-terminated, truncated to 72 bytes (callers reject > 72 before this).
fn key(password: &str) -> Vec<u8> {
    let mut k = Vec::with_capacity(password.len() + 1);
    k.extend_from_slice(password.as_bytes());
    k.push(0);
    k.truncate(72);
    k
}

pub fn hash(password: &str) -> Option<String> {
    let mut salt = [0u8; 16];
    getrandom::fill(&mut salt).ok()?;
    let out = raw(COST, &salt, &key(password));
    Some(format!("$2b${COST:02}${}{}", B64.encode(salt), B64.encode(&out[..23])))
}

pub fn verify(password: &str, hash: &str) -> bool {
    // $2b$10$<22 salt><31 hash>
    let mut parts = hash.split('$').filter(|s| !s.is_empty());
    let (Some(prefix), Some(cost), Some(rest), None) = (parts.next(), parts.next(), parts.next(), parts.next()) else {
        return false;
    };
    if !matches!(prefix, "2a" | "2b" | "2x" | "2y") || rest.len() != 53 || !rest.is_char_boundary(22) {
        return false;
    }
    let Ok(cost) = cost.parse::<u32>() else { return false };
    if !(4..=31).contains(&cost) {
        return false;
    }
    let (Ok(salt), Ok(expected)) = (B64.decode(&rest[..22]), B64.decode(&rest[22..])) else { return false };
    let Ok(salt) = <[u8; 16]>::try_from(salt.as_slice()) else { return false };
    let out = raw(cost, &salt, &key(password));
    // constant-time compare
    expected.len() == 23 && expected.iter().zip(&out[..23]).fold(0u8, |acc, (a, b)| acc | (a ^ b)) == 0
}

#[cfg(test)]
mod tests {
    #[test]
    fn matches_bcrypt_crate() {
        let h = bcrypt::hash("password123", 10).unwrap();
        assert!(super::verify("password123", &h));
        assert!(!super::verify("password124", &h));
        let mine = super::hash("hunter2").unwrap();
        assert!(bcrypt::verify("hunter2", &mine).unwrap());
        // a seeded hash (users.id = 1 in the challenge seed)
        assert!(super::verify("password123", "$2a$10$ZSfEoPvlcsj2XfvsSeK25em4NZ9Jm7ntGqXuLgQfHEeZPYB8899wq"));
    }
}
