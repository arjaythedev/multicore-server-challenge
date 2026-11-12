//! bcrypt (cost 10) runs on a small pool of plain threads so that ~50 ms hashes never block an
//! io_uring event loop. Results go back through a per-worker channel and an eventfd wake-up.

use std::sync::Arc;
use std::thread;

use crossbeam_channel::{bounded, Receiver, Sender};

pub const BCRYPT_COST: u32 = 10;

pub enum BJob {
    Hash {
        wid: usize,
        ci: u32,
        gid: u32,
        pw: String,
    },
    Verify {
        wid: usize,
        ci: u32,
        gid: u32,
        pw: String,
        hash: String,
    },
}

pub enum BOut {
    Hashed { ci: u32, gid: u32, res: Option<String> },
    Verified { ci: u32, gid: u32, ok: bool },
}

/// One entry per io worker: its result channel and the eventfd that wakes its ring.
pub type Outs = Arc<Vec<(Sender<BOut>, i32)>>;

pub fn start(threads: usize, outs: Vec<(Sender<BOut>, i32)>) -> Sender<BJob> {
    let (tx, rx) = bounded::<BJob>(65_536);
    let outs: Outs = Arc::new(outs);
    for i in 0..threads {
        let rx = rx.clone();
        let outs = Arc::clone(&outs);
        thread::Builder::new()
            .name(format!("bcrypt-{}", i))
            .spawn(move || {
                demote_thread();
                run(rx, outs);
            })
            .expect("spawn bcrypt thread");
    }
    tx
}

/// SCHED_BATCH: the scheduler will not preempt an io worker in favour of a freshly woken hash thread.
fn demote_thread() {
    unsafe {
        let param = libc::sched_param { sched_priority: 0 };
        libc::sched_setscheduler(0, libc::SCHED_BATCH, &param);
    }
}

fn notify(efd: i32) {
    let one: u64 = 1;
    unsafe {
        libc::write(efd, &one as *const u64 as *const libc::c_void, 8);
    }
}

fn run(rx: Receiver<BJob>, outs: Outs) {
    while let Ok(job) = rx.recv() {
        match job {
            BJob::Hash { wid, ci, gid, pw } => {
                let res = bcrypt::hash(pw.as_bytes(), BCRYPT_COST).ok();
                let (tx, efd) = &outs[wid];
                let _ = tx.send(BOut::Hashed { ci, gid, res });
                notify(*efd);
            }
            BJob::Verify { wid, ci, gid, pw, hash } => {
                let ok = bcrypt::verify(pw.as_bytes(), &hash).unwrap_or(false);
                let (tx, efd) = &outs[wid];
                let _ = tx.send(BOut::Verified { ci, gid, ok });
                notify(*efd);
            }
        }
    }
}
