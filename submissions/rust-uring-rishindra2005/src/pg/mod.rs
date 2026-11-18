//! PostgreSQL wire protocol client, prepared statement catalog, binary decoders, and warm-up routine.
//!
//! Clean-room implementation for high-throughput multicore server.

pub mod decode;
pub mod stmt;
pub mod warm;
pub mod wire;

pub use decode::{BinaryDecoder, BinaryEncoder, BinaryRow};
pub use stmt::{PREPARED_STATEMENTS, SESSION_INIT_SQL};
pub use warm::run_warmup;
pub use wire::{PgError, PgWire, Pipeline};
