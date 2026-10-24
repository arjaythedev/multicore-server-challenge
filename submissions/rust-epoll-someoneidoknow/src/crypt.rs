use std::collections::VecDeque;
use std::os::fd::RawFd;
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use ring::rand::{SecureRandom, SystemRandom};

use crate::api::{CryptDone, CryptReq, Job, Work};
use crate::bcrypt_lanes::{self, LANES, Setting};
use crate::sys;

const COST: u32 = 10;

pub struct Mailbox {
    pub efd: RawFd,
    pub done: Mutex<Vec<(Job, CryptDone)>>,
}

pub struct CryptPool {
    queue: Mutex<VecDeque<(Instant, usize, CryptReq)>>,
    ready: Condvar,
    mailboxes: Vec<Mailbox>,
    wait: Duration,
}

impl CryptPool {
    pub fn start(threads: usize, wait: Duration, mailboxes: Vec<Mailbox>) -> Arc<CryptPool> {
        let pool = Arc::new(CryptPool {
            queue: Mutex::new(VecDeque::new()),
            ready: Condvar::new(),
            mailboxes,
            wait,
        });
        for _ in 0..threads {
            let pool = Arc::clone(&pool);
            std::thread::spawn(move || pool.run());
        }
        pool
    }

    pub fn mailbox(&self, id: usize) -> &Mailbox {
        &self.mailboxes[id]
    }

    pub fn submit(&self, loop_id: usize, req: CryptReq) {
        let mut q = self.queue.lock().unwrap();
        q.push_back((Instant::now(), loop_id, req));
        if q.len() == 1 || q.len() >= LANES {
            self.ready.notify_one();
        }
    }

    fn take(&self) -> Vec<(usize, CryptReq)> {
        let mut q = self.queue.lock().unwrap();
        loop {
            match q.front() {
                None => q = self.ready.wait(q).unwrap(),
                Some((since, _, _)) if q.len() < LANES => {
                    let deadline = *since + self.wait;
                    let now = Instant::now();
                    if now >= deadline {
                        break;
                    }
                    q = self.ready.wait_timeout(q, deadline - now).unwrap().0;
                }
                Some(_) => break,
            }
        }
        let n = q.len().min(LANES);
        let batch = q.drain(..n).map(|(_, l, r)| (l, r)).collect();
        if !q.is_empty() {
            self.ready.notify_one();
        }
        batch
    }

    fn run(&self) {
        let rng = SystemRandom::new();
        loop {
            let batch = self.take();
            let mut salts = vec![[0u8; 16]; batch.len()];
            for s in &mut salts {
                let _ = rng.fill(s);
            }
            let jobs: Vec<bcrypt_lanes::Job> = batch
                .iter()
                .zip(&salts)
                .map(|((_, req), salt)| match &req.work {
                    Work::Hash(pw) => bcrypt_lanes::Job {
                        password: pw,
                        setting: Setting::Hash {
                            cost: COST,
                            salt: *salt,
                        },
                    },
                    Work::Verify(pw, stored) => bcrypt_lanes::Job {
                        password: pw,
                        setting: Setting::Verify { stored },
                    },
                })
                .collect();
            let results = bcrypt_lanes::run(&jobs);
            drop(jobs);
            for ((loop_id, req), out) in batch.into_iter().zip(results) {
                let done = match (&req.work, out) {
                    (Work::Hash(_), Some(h)) => CryptDone::Hashed(h),
                    (Work::Verify(..), Some(v)) => CryptDone::Verified(v == b"1"),
                    (Work::Verify(..), None) => CryptDone::Verified(false),
                    (Work::Hash(_), None) => CryptDone::Failed,
                };
                let mb = &self.mailboxes[loop_id];
                mb.done.lock().unwrap().push((req.job, done));
                sys::eventfd_signal(mb.efd);
            }
        }
    }
}
