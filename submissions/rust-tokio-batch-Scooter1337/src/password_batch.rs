//! Bounded CPU work, with independently salted hashes interleaved on each worker.
use std::{ffi::CStr, sync::Arc, time::Duration};
use subtle::ConstantTimeEq;
use tokio::{
    sync::{Semaphore, mpsc, oneshot},
    time::Instant,
};

enum Output {
    Hash(String),
    Verified(bool),
}
struct Job {
    password: String,
    hash: Option<String>,
    enqueued: Instant,
    reply: oneshot::Sender<Result<Output, String>>,
}
pub struct Pool(mpsc::Sender<Job>);
/// The error for a job that waited past `BCRYPT_SHED_MS` (default 8000) without starting: by the time it finished,
/// a client with a 10 s timeout would have given up, so the slot goes to the next job instead.
pub const BUSY: &str = "bcrypt queue is too long";
impl Pool {
    pub fn new(slots: usize) -> Self {
        super::native::batch_self_test();
        let wait = Duration::from_millis(
            std::env::var("BCRYPT_BATCH_MS")
                .ok()
                .map(|s| s.parse::<u64>().expect("BCRYPT_BATCH_MS"))
                .unwrap_or(160),
        );
        let shed = Duration::from_millis(
            std::env::var("BCRYPT_SHED_MS")
                .ok()
                .map(|s| s.parse::<u64>().expect("BCRYPT_SHED_MS"))
                .unwrap_or(8000),
        );
        let fresh = move |j: Job| {
            if j.enqueued.elapsed() < shed {
                return Some(j);
            }
            let _ = j.reply.send(Err(BUSY.into()));
            None
        };
        let (tx, mut rx) = mpsc::channel::<Job>(1024);
        let permits = Arc::new(Semaphore::new(slots));
        tokio::spawn(async move {
            while let Some(first) = rx.recv().await {
                let Ok(permit) = permits.clone().acquire_owned().await else {
                    break;
                };
                let Some(first) = fresh(first) else {
                    continue;
                };
                let deadline = first.enqueued + wait;
                let mut jobs = Vec::with_capacity(5);
                jobs.push(first);
                while jobs.len() < 5 {
                    match rx.try_recv() {
                        Ok(j) => jobs.extend(fresh(j)),
                        Err(_) if Instant::now() < deadline => {
                            match tokio::time::timeout_at(deadline, rx.recv()).await {
                                Ok(Some(j)) => jobs.extend(fresh(j)),
                                _ => break,
                            }
                        }
                        Err(_) => break,
                    }
                }
                tokio::task::spawn_blocking(move || {
                    let _permit = permit;
                    compute(jobs);
                });
            }
        });
        Self(tx)
    }
    async fn submit(&self, password: String, hash: Option<String>) -> Result<Output, String> {
        let (reply, rx) = oneshot::channel();
        self.0
            .send(Job {
                password,
                hash,
                reply,
                enqueued: Instant::now(),
            })
            .await
            .map_err(|_| "bcrypt dispatcher closed")?;
        rx.await.map_err(|_| "bcrypt worker failed")?
    }
    pub async fn hash(&self, password: String) -> Result<String, String> {
        match self.submit(password, None).await? {
            Output::Hash(h) => Ok(h),
            _ => Err("unexpected bcrypt result".into()),
        }
    }
    pub async fn verify(&self, password: String, hash: String) -> Result<bool, String> {
        match self.submit(password, Some(hash)).await? {
            Output::Verified(v) => Ok(v),
            _ => Err("unexpected bcrypt result".into()),
        }
    }
}
fn compute(jobs: Vec<Job>) {
    let mut settings = Vec::with_capacity(5);
    for (i, j) in jobs.iter().enumerate() {
        if j.password.len() > 72 || j.password.as_bytes().contains(&0) {
            continue;
        }
        let mut setting = [0u8; 61];
        if let Some(h) = &j.hash {
            if !super::native::valid_setting(h) {
                continue;
            }
            setting[..60].copy_from_slice(h.as_bytes());
        } else {
            let Ok(salt) = super::native::salt() else {
                continue;
            };
            setting[..30].copy_from_slice(&salt);
        }
        settings.push((i, setting));
    }
    let inputs: Vec<_> = settings
        .iter()
        .map(|(i, s)| {
            (
                jobs[*i].password.as_str(),
                CStr::from_bytes_until_nul(s).expect("terminated bcrypt setting"),
            )
        })
        .collect();
    let mut computed = [None; 5];
    if let Some(hashes) = super::native::compute_batch(&inputs) {
        for ((i, _), h) in settings.iter().zip(hashes) {
            computed[*i] = Some(h);
        }
    }
    for (i, j) in jobs.into_iter().enumerate() {
        let result = if let Some(h) = computed[i] {
            match j.hash {
                Some(expected) => Ok(Output::Verified(bool::from(
                    h.as_slice().ct_eq(expected.as_bytes()),
                ))),
                None => String::from_utf8(h.to_vec())
                    .map(Output::Hash)
                    .map_err(|e| e.to_string()),
            }
        } else {
            match j.hash {
                Some(h) => Ok(Output::Verified(super::verify(&j.password, &h))),
                None => super::hash(&j.password).map(Output::Hash),
            }
        };
        let _ = j.reply.send(result);
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn interleaved_matches_portable() {
        use std::ffi::CString;
        for variant in ["2a", "2b", "2y"] {
            let mut passwords = [
                String::new(),
                "één 🙂".into(),
                "x".repeat(72),
                "different password".into(),
                "высокие байты \u{a3}".into(),
            ];
            for round in 0..4 {
                passwords[3] = format!(
                    "random-{round}-{}",
                    super::super::native::salt().unwrap()[7]
                );
                let settings: Vec<_> = passwords
                    .iter()
                    .map(|p| {
                        let h = bcrypt::hash(p, 4).unwrap();
                        CString::new(format!("${variant}{}", &h[3..])).unwrap()
                    })
                    .collect();
                for n in 2..=5 {
                    let inputs: Vec<_> = passwords
                        .iter()
                        .zip(&settings)
                        .take(n)
                        .map(|(p, s)| (p.as_str(), s.as_c_str()))
                        .collect();
                    let actual = super::super::native::compute_batch(&inputs).unwrap();
                    for (i, h) in actual.iter().enumerate() {
                        assert_eq!(h.as_slice(), settings[i].as_bytes());
                        assert!(
                            bcrypt::verify(&passwords[i], std::str::from_utf8(h).unwrap()).unwrap()
                        );
                    }
                }
            }
        }
    }
    #[tokio::test]
    async fn mixed_jobs_and_independent_salts() {
        let pool = std::sync::Arc::new(super::Pool::new(2));
        let mut tasks = Vec::new();
        for p in ["password123", "één 🙂", "abc\0def", "72bytes"]
            .into_iter()
            .cycle()
            .take(12)
        {
            let pool = pool.clone();
            tasks.push(tokio::spawn(async move {
                let h = pool.hash(p.into()).await.unwrap();
                assert!(bcrypt::verify(p, &h).unwrap());
                assert!(pool.verify(p.into(), h.clone()).await.unwrap());
                assert!(!pool.verify("incorrect".into(), h).await.unwrap());
                assert!(!pool.verify(p.into(), "$2b$10$bad".into()).await.unwrap());
            }));
        }
        for t in tasks {
            t.await.unwrap();
        }
        let (a, b) = tokio::join!(pool.hash("same".into()), pool.hash("same".into()));
        assert_ne!(a.unwrap(), b.unwrap());
    }
}
