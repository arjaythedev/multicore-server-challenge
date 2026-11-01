//! [`Sink`]: where finished responses go during a batch, and the bookkeeping that proves every request got one.
//!
//! A response is rendered once, straight into a pooled buffer that reserves room for the HTTP head in front
//! (`ResponseBuf`); that same `Vec` travels to the io thread inside the [`Reply`]. Nothing is copied on the way
//! except the shared tag list, which every `GET /api/tags` reply must own.

use crate::app::jobs::{Origin, ReadJob};
use crate::http::{ResponseBuf, Status};
use crate::json::JsonWriter;
use crate::net::Reply;
use crate::pool::POOL;

use super::error::ReadError;

/// What the client is told when the database or the mapping failed.
const INTERNAL_MESSAGE: &str = "internal error";
const UNAVAILABLE_MESSAGE: &str = "database unavailable";

#[derive(Default)]
pub struct Sink {
    pub replies: Vec<Reply>,
    /// One flag per request of the group being answered: has it received its reply?
    answered: Vec<bool>,
}

impl Sink {
    /// Forgets the previous batch's replies (their buffers already moved to the io threads).
    pub fn clear(&mut self) {
        self.replies.clear();
    }

    /// Starts the bookkeeping for a group of `members` requests.
    pub fn begin_group(&mut self, members: usize) {
        self.answered.clear();
        self.answered.resize(members, false);
    }

    /// Marks member `ord - 1` (SQL ordinality is 1-based) answered. Errors if `ord` is out of range or the member
    /// was answered before.
    pub fn claim(&mut self, ord: i64) -> Result<usize, ReadError> {
        let slot = usize::try_from(ord - 1)
            .ok()
            .and_then(|i| self.answered.get_mut(i).map(|f| (i, f)));
        match slot {
            Some((i, flag)) if !*flag => {
                *flag = true;
                Ok(i)
            }
            Some(_) => Err(ReadError::Inconsistent("request answered twice")),
            None => Err(ReadError::Inconsistent("ordinality outside the batch")),
        }
    }

    /// Answers every member of the group that no row answered.
    pub fn fail_unanswered(&mut self, members: &[u32], jobs: &[ReadJob], status: Status) {
        for (i, &job) in members.iter().enumerate() {
            if !self.answered.get(i).copied().unwrap_or(false) {
                self.error(jobs[job as usize].origin, status, message_for(status));
            }
        }
    }

    /// Renders a JSON document into a pooled response buffer. If `render` fails the client gets a 500 instead.
    pub fn json(
        &mut self,
        origin: Origin,
        status: Status,
        render: impl FnOnce(&mut JsonWriter<'_>) -> Result<(), ReadError>,
    ) {
        let mut response = begin_response();
        let rendered = render(&mut JsonWriter::new(response.body()));
        match rendered {
            Ok(()) => self.finish(origin, response, status),
            Err(_) => self.error_in(origin, response, Status::Internal, INTERNAL_MESSAGE),
        }
    }

    /// A response whose body is already rendered (the shared tag list).
    pub fn raw(&mut self, origin: Origin, status: Status, body: &[u8]) {
        let mut response = begin_response();
        response.body().extend_from_slice(body);
        self.finish(origin, response, status);
    }

    /// `{"errors":{"body":["message"]}}` with `status`.
    pub fn error(&mut self, origin: Origin, status: Status, message: &str) {
        self.error_in(origin, begin_response(), status, message);
    }

    fn error_in(
        &mut self,
        origin: Origin,
        mut response: ResponseBuf,
        status: Status,
        message: &str,
    ) {
        let start = response.finish_error(status, origin.keep_alive, message);
        self.push(origin, response, start);
    }

    fn finish(&mut self, origin: Origin, mut response: ResponseBuf, status: Status) {
        let start = response.finish(status, origin.keep_alive);
        self.push(origin, response, start);
    }

    fn push(&mut self, origin: Origin, response: ResponseBuf, start: usize) {
        self.replies.push(Reply {
            conn: origin.conn,
            bytes: response.into_vec(),
            start,
            close: !origin.keep_alive,
        });
    }
}

fn begin_response() -> ResponseBuf {
    let mut response = ResponseBuf::from_vec(POOL.get());
    response.begin();
    response
}

fn message_for(status: Status) -> &'static str {
    match status {
        Status::ServiceUnavailable => UNAVAILABLE_MESSAGE,
        _ => INTERNAL_MESSAGE,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::read::queue::tests::job;

    fn parse(reply: &Reply) -> (String, String) {
        let text = String::from_utf8_lossy(&reply.bytes[reply.start..]).into_owned();
        let (head, body) = text.split_once("\r\n\r\n").unwrap_or((&text, ""));
        (
            head.lines().next().unwrap_or("").to_owned(),
            body.to_owned(),
        )
    }

    #[test]
    fn claim_accepts_each_ordinal_once() {
        let mut sink = Sink::default();
        sink.begin_group(2);
        assert_eq!(sink.claim(2).unwrap(), 1);
        assert!(sink.claim(2).is_err());
        assert!(sink.claim(0).is_err());
        assert!(sink.claim(3).is_err());
        assert_eq!(sink.claim(1).unwrap(), 0);
    }

    #[test]
    fn unanswered_members_get_the_failure_and_answered_ones_do_not() {
        let jobs = vec![
            job(1, std::time::Instant::now()),
            job(2, std::time::Instant::now()),
        ];
        let mut sink = Sink::default();
        sink.begin_group(2);
        sink.claim(1).unwrap();
        sink.fail_unanswered(&[0, 1], &jobs, Status::Internal);
        assert_eq!(sink.replies.len(), 1);
        let (status, body) = parse(&sink.replies[0]);
        assert_eq!(status, "HTTP/1.1 500 Internal Server Error");
        assert_eq!(body, r#"{"errors":{"body":["internal error"]}}"#);
    }

    #[test]
    fn a_failed_render_becomes_a_500_and_a_good_one_keeps_its_status() {
        let origin = job(1, std::time::Instant::now()).origin;
        let mut sink = Sink::default();
        sink.json(origin, Status::Ok, |w| {
            w.begin_object();
            w.end_object();
            Ok(())
        });
        sink.json(origin, Status::Ok, |_| Err(ReadError::Inconsistent("test")));
        sink.raw(origin, Status::NotFound, b"{}");
        let parsed: Vec<_> = sink.replies.iter().map(parse).collect();
        assert_eq!(parsed[0], ("HTTP/1.1 200 OK".to_owned(), "{}".to_owned()));
        assert_eq!(parsed[1].0, "HTTP/1.1 500 Internal Server Error");
        assert_eq!(
            parsed[2],
            ("HTTP/1.1 404 Not Found".to_owned(), "{}".to_owned())
        );
    }
}
