//! Runtime primitives: SPSC rings, arena allocators, thread spawning and scheduling.

pub mod spsc;
pub mod arena;
pub mod thread;

pub use spsc::{SpscQueue, STATE_AWAKE, STATE_SLEEPING};
pub use arena::BatchArena;
pub use thread::{spawn_worker, pin_current_thread, apply_sched_policy, create_eventfd, SchedPolicy};
