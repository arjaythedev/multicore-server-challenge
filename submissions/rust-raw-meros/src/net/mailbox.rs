//! How lane threads hand finished responses to io threads: a mutexed vector and an `eventfd` that wakes the
//! owner's epoll loop. One lock round-trip and one `write` per batch of replies, not per reply.

use std::sync::{Arc, Mutex};

use super::Reply;
use crate::sys::EventFd;

/// Replies waiting for one io thread.
pub struct Mailbox {
    inbox: Mutex<Vec<Reply>>,
    wake: EventFd,
}

impl Mailbox {
    pub fn new() -> std::io::Result<Mailbox> {
        Ok(Mailbox {
            inbox: Mutex::new(Vec::new()),
            wake: EventFd::new()?,
        })
    }

    /// The descriptor an io thread registers with its epoll.
    pub fn wake_fd(&self) -> std::os::fd::RawFd {
        self.wake.raw()
    }

    /// Queues replies and wakes the owner once. Leaves `replies` empty.
    pub fn post_all(&self, replies: &mut Vec<Reply>) {
        if replies.is_empty() {
            return;
        }
        let was_empty = {
            let mut inbox = self.inbox.lock().unwrap_or_else(|e| e.into_inner());
            let was_empty = inbox.is_empty();
            inbox.append(replies);
            was_empty
        };
        // Only the first reply into an empty inbox needs a wake-up; the owner drains everything it finds.
        if was_empty {
            self.wake.notify();
        }
    }

    /// Moves every queued reply into `out` (owner side) and resets the wake-up counter.
    pub fn take_all(&self, out: &mut Vec<Reply>) {
        self.wake.drain();
        let mut inbox = self.inbox.lock().unwrap_or_else(|e| e.into_inner());
        std::mem::swap(&mut *inbox, out);
    }
}

/// The mailboxes of all io threads, indexed by `ConnId::io`.
#[derive(Clone)]
pub struct Mailboxes(Arc<Vec<Mailbox>>);

impl Mailboxes {
    pub fn new(count: usize) -> std::io::Result<Mailboxes> {
        let boxes = (0..count)
            .map(|_| Mailbox::new())
            .collect::<std::io::Result<Vec<_>>>()?;
        Ok(Mailboxes(Arc::new(boxes)))
    }

    pub fn get(&self, io: usize) -> &Mailbox {
        &self.0[io]
    }

    /// Posts one finished response to the thread that owns its connection.
    pub fn post(&self, reply: Reply) {
        let mut one = vec![reply];
        let io = one[0].conn.io as usize;
        self.0[io].post_all(&mut one);
    }

    /// Posts a batch of finished responses, grouped by owner so each owner is woken once.
    pub fn post_many(&self, replies: Vec<Reply>) {
        let mut per_owner: Vec<Vec<Reply>> = (0..self.0.len()).map(|_| Vec::new()).collect();
        for reply in replies {
            per_owner[reply.conn.io as usize].push(reply);
        }
        for (io, mut group) in per_owner.into_iter().enumerate() {
            self.0[io].post_all(&mut group);
        }
    }
}
