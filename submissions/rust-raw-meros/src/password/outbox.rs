//! Where finished password work goes. A trait with one production type keeps the worker generic (static
//! dispatch) while tests capture results without a socket or a database.

use std::sync::Arc;

use crate::app::jobs::WriteJob;
use crate::net::{Mailboxes, Reply};
use crate::write::WriteQueue;

/// Destination of a worker's results.
pub trait Outbox {
    /// A finished HTTP response for a client.
    fn reply(&self, reply: Reply);
    /// A hashed register or password change that continues as a write.
    fn write(&self, job: WriteJob);
}

/// The real destinations: the io threads' mailboxes and the write queue.
pub struct Live {
    mailboxes: Mailboxes,
    writes: Arc<WriteQueue>,
}

impl Live {
    pub fn new(mailboxes: Mailboxes, writes: Arc<WriteQueue>) -> Live {
        Live { mailboxes, writes }
    }
}

impl Outbox for Live {
    fn reply(&self, reply: Reply) {
        self.mailboxes.post(reply);
    }

    fn write(&self, job: WriteJob) {
        self.writes.push(job);
    }
}
