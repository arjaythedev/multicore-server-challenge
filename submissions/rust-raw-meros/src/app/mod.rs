//! HTTP-facing application layer. See DESIGN.md. STUB: `App::handle` is filled in by the integrator.
pub mod jobs;
pub mod route;
pub mod slug;

use crate::http::ResponseBuf;
use crate::net::{ConnId, Step};

pub struct App {}

impl App {
    pub fn handle(&self, buf: Vec<u8>, _conn: ConnId, out: &mut ResponseBuf) -> Step {
        let start = out.finish_error(crate::http::Status::NotFound, true, "not implemented");
        Step::Answered { consumed: buf.len(), buf, start, keep_alive: true }
    }
}
