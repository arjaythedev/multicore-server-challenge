//! A blocking Postgres client, written for one job: lane threads that send many statements per round trip.
//!
//! * `Config` / `Connection::connect`: URL parsing, startup, trust / cleartext / SCRAM-SHA-256 authentication.
//! * `Connection::prepare` + `push` + `flush_and_collect`: named server-side statements, Bind/Execute pipelined,
//!   one Sync, replies parsed straight into a reusable [`Results`] arena.
//! * `Param` and `Row`: binary encodings of the handful of types the server uses.
//!
//! Not handled on purpose: TLS, COPY, LISTEN/NOTIFY, cancellation, text-format results, portals with row limits,
//! MD5/GSS authentication, multi-host URLs.
//!
//! File map: `wire` (message encoders), `codec` (value + array codecs), `frame` (stream -> messages), `transport`
//! (socket I/O incl. deadlock-free large writes), `startup` + `scram` (login), `collect` + `results` + `row`
//! (reply arena), `conn` (the public connection), `config`, `error`.

mod codec;
mod collect;
mod config;
mod conn;
mod error;
mod frame;
mod results;
mod row;
mod scram;
mod startup;
mod transport;
mod wire;

#[cfg(test)]
mod live_tests;

pub use codec::{
    BOOL, INT4, INT8, INT8_ARRAY, Int8Array, Param, TEXT, TEXT_ARRAY, TIMESTAMPTZ, TextArray,
};
pub use config::Config;
pub use conn::{Connection, Stmt};
pub use error::{PgError, SQLSTATE_UNIQUE_VIOLATION, ServerError};
pub use results::{Results, Rows, StmtResult};
pub use row::Row;
