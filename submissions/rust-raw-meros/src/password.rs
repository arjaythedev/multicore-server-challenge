//! Password service: bcrypt on dedicated threads. STUB: replaced by its owner.
use crate::app::jobs::PasswordJob;

/// Queue of password jobs shared by the read lanes (login) and the app (register, change password).
pub struct PasswordQueue {}

impl PasswordQueue {
    pub fn push(&self, _job: PasswordJob) {
        todo!("password queue")
    }
}
