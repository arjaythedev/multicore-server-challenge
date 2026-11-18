//! JWT (HS256) and bcrypt.
//!
//! * Every request verifies the HMAC signature and `exp` from scratch; nothing about a token or a
//!   password is ever remembered (rule 5).
//! * bcrypt (cost 10, tens of milliseconds of pure CPU) runs on its own small pool of OS threads at a
//!   lower scheduling priority, so it can never stall a request thread's event loop and it yields to
//!   request handling when the box is saturated.

use std::sync::mpsc::{channel, Sender};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64;
use base64::Engine as _;
use hmac::{Hmac, Mac, KeyInit};
use serde::Deserialize;
use sha2::Sha256;

type HmacSha256 = Hmac<Sha256>;

const TOKEN_LIFETIME_SECS: u64 = 30 * 24 * 3600;

fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

#[derive(Deserialize)]
struct JwtHeader {
    alg: String,
}

#[derive(Deserialize)]
struct JwtClaims {
    sub: String,
    exp: f64,
}

pub struct Jwt {
    key: HmacSha256,
    header_b64: String,
}

impl Jwt {
    pub fn new(secret: &str) -> Jwt {
        let key = HmacSha256::new_from_slice(secret.as_bytes()).expect("HMAC accepts keys of any size");
        Jwt { key, header_b64: B64.encode(br#"{"alg":"HS256","typ":"JWT"}"#) }
    }

    /// `header.payload.signature` with claims `{"sub":"<id>","iat":now,"exp":now+30d}`.
    pub fn sign(&self, user_id: i64) -> String {
        let now = now_secs();
        let payload = format!(
            "{{\"sub\":\"{}\",\"iat\":{},\"exp\":{}}}",
            user_id,
            now,
            now + TOKEN_LIFETIME_SECS
        );
        let mut token = String::with_capacity(self.header_b64.len() + 100);
        token.push_str(&self.header_b64);
        token.push('.');
        B64.encode_string(payload.as_bytes(), &mut token);
        let mut mac = self.key.clone();
        mac.update(token.as_bytes());
        let sig = mac.finalize().into_bytes();
        token.push('.');
        B64.encode_string(sig, &mut token);
        token
    }

    /// Returns the user id if the token is a well-formed HS256 JWT signed with our secret and not
    /// expired. Any other `alg` (including `none`) is rejected.
    pub fn verify(&self, token: &str) -> Option<i64> {
        let mut parts = token.split('.');
        let h = parts.next()?;
        let p = parts.next()?;
        let s = parts.next()?;
        if parts.next().is_some() {
            return None;
        }

        // Signature first (constant-time compare inside verify_slice).
        let sig = B64.decode(s).ok()?;
        if sig.len() != 32 {
            return None;
        }
        let mut mac = self.key.clone();
        mac.update(h.as_bytes());
        mac.update(b".");
        mac.update(p.as_bytes());
        mac.verify_slice(&sig).ok()?;

        // Header: tokens we minted have a fixed header, everything else is parsed and must say HS256.
        if h != self.header_b64 {
            let hb = B64.decode(h).ok()?;
            let hdr: JwtHeader = serde_json::from_slice(&hb).ok()?;
            if hdr.alg != "HS256" {
                return None;
            }
        }

        let pb = B64.decode(p).ok()?;
        let claims: JwtClaims = serde_json::from_slice(&pb).ok()?;
        if !(claims.exp > now_secs() as f64) {
            return None;
        }
        if claims.sub.is_empty() || !claims.sub.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        let id: i64 = claims.sub.parse().ok()?;
        if id > 0 {
            Some(id)
        } else {
            None
        }
    }
}

type Job = Box<dyn FnOnce() + Send + 'static>;

pub struct BcryptPool {
    tx: Sender<Job>,
}

impl BcryptPool {
    /// `nice` > 0 lowers the scheduling priority of the pool's threads (Linux; no-op elsewhere).
    pub fn new(threads: usize, nice: i32) -> BcryptPool {
        let (tx, rx) = channel::<Job>();
        let rx = Arc::new(Mutex::new(rx));
        for i in 0..threads.max(1) {
            let rx = rx.clone();
            std::thread::Builder::new()
                .name(format!("bcrypt-{i}"))
                .spawn(move || {
                    if nice > 0 {
                        lower_priority(nice);
                    }
                    loop {
                        let job = {
                            let guard = match rx.lock() {
                                Ok(g) => g,
                                Err(poisoned) => poisoned.into_inner(),
                            };
                            guard.recv()
                        };
                        match job {
                            Ok(job) => job(),
                            Err(_) => break,
                        }
                    }
                })
                .expect("spawn bcrypt thread");
        }
        BcryptPool { tx }
    }

    /// bcrypt cost 10.
    pub async fn hash(&self, password: String) -> Option<String> {
        let (otx, orx) = tokio::sync::oneshot::channel();
        let job: Job = Box::new(move || {
            let _ = otx.send(bcrypt::hash(password, 10).ok());
        });
        self.tx.send(job).ok()?;
        orx.await.ok().flatten()
    }

    pub async fn verify(&self, password: String, hash: String) -> bool {
        let (otx, orx) = tokio::sync::oneshot::channel();
        let job: Job = Box::new(move || {
            let _ = otx.send(bcrypt::verify(password, &hash).unwrap_or(false));
        });
        if self.tx.send(job).is_err() {
            return false;
        }
        orx.await.unwrap_or(false)
    }
}

#[cfg(target_os = "linux")]
fn lower_priority(nice: i32) {
    // On Linux the nice value is per thread; setpriority(PRIO_PROCESS, tid, ..) affects only this thread.
    unsafe {
        let tid = libc::syscall(libc::SYS_gettid) as libc::id_t;
        libc::setpriority(libc::PRIO_PROCESS, tid, nice);
    }
}

#[cfg(not(target_os = "linux"))]
fn lower_priority(_nice: i32) {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sign_then_verify() {
        let j = Jwt::new("secret");
        let t = j.sign(42);
        assert_eq!(j.verify(&t), Some(42));
    }

    #[test]
    fn rejects_tampering_and_wrong_secret() {
        let j = Jwt::new("secret");
        let t = j.sign(42);
        let other = Jwt::new("other");
        assert_eq!(other.verify(&t), None);
        let mut bad = t.clone();
        bad.push('x');
        assert_eq!(j.verify(&bad), None);
        assert_eq!(j.verify("not.a.token"), None);
        assert_eq!(j.verify(""), None);
    }

    #[test]
    fn rejects_alg_none_and_expired() {
        let j = Jwt::new("secret");
        let header = B64.encode(br#"{"alg":"none","typ":"JWT"}"#);
        let payload = B64.encode(br#"{"sub":"1","exp":99999999999}"#);
        assert_eq!(j.verify(&format!("{header}.{payload}.")), None);

        // correctly signed, but alg is not HS256
        let header = B64.encode(br#"{"alg":"HS384","typ":"JWT"}"#);
        let signing = format!("{header}.{payload}");
        let mut mac = HmacSha256::new_from_slice(b"secret").unwrap();
        mac.update(signing.as_bytes());
        let sig = B64.encode(mac.finalize().into_bytes());
        assert_eq!(j.verify(&format!("{signing}.{sig}")), None);

        // correctly signed HS256 but expired
        let header = B64.encode(br#"{"alg":"HS256","typ":"JWT"}"#);
        let payload = B64.encode(br#"{"sub":"1","exp":1}"#);
        let signing = format!("{header}.{payload}");
        let mut mac = HmacSha256::new_from_slice(b"secret").unwrap();
        mac.update(signing.as_bytes());
        let sig = B64.encode(mac.finalize().into_bytes());
        assert_eq!(j.verify(&format!("{signing}.{sig}")), None);
    }
}