//! Write lanes: group commit. STUB: replaced by its owner.
use crate::app::jobs::WriteJob;

pub struct WriteQueue {}

impl WriteQueue {
    pub fn push(&self, _job: WriteJob) {
        todo!("write queue")
    }
}
