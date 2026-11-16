//! Outgoing response queue, partial-send state machine, and batched submission.
//! Handles fixed-descriptor sends (IOSQE_FIXED_FILE) and socket closing without drops.
//!
//! Invariants (a violation is a use-after-free or a hung client):
//! - At most one SEND per connection is with the kernel (`send_inflight`). Its buffer, `pending_write`,
//!   is never resized, replaced or freed until that SEND's CQE arrives.
//! - Replies arriving meanwhile go to `queued_write` and are sent after the in-flight one completes.
//! - A reply is never dropped because the SQ is full: the slot is parked in `stalled` and retried.
//! - Every SEND carries the slot generation, so a CQE of a closed connection never touches its successor.

use crate::net::conn::ConnTable;
use crate::net::uring::*;
use crate::types::{ConnRef, Reply};

/// make_user_data(TAG_SEND, slot, gen)
pub type SendUd = fn(u32, u32) -> u64;

/// What the reactor must do after a SEND completion.
#[derive(Debug, PartialEq, Eq)]
pub enum SendOutcome {
    /// Nothing (keep-alive connection, more data queued, or a stale CQE).
    Keep,
    /// Close the connection now (error, `Connection: close` fully sent, or a close deferred by an in-flight send).
    Close,
}

pub struct OutgoingQueue {
    pub pending_replies: Vec<Reply>,
    /// Connections whose `pending_write` is ready but got no SQE (SQ full); retried on the next flush.
    pub stalled: Vec<ConnRef>,
}

impl OutgoingQueue {
    pub fn new() -> Self {
        Self {
            pending_replies: Vec::with_capacity(512),
            stalled: Vec::new(),
        }
    }

    #[inline(always)]
    pub fn enqueue(&mut self, reply: Reply) {
        self.pending_replies.push(reply);
    }

    /// Queues one SEND for the unsent tail of the slot's `pending_write`. Returns false if no SQE was free.
    fn submit_send(ring: &mut IoUringInstance, conn_table: &mut ConnTable, slot_idx: u32, ud: SendUd) -> bool {
        let s = &mut conn_table.slots[slot_idx as usize];
        let Some(sqe) = ring.get_sqe_flush() else { return false };
        sqe.opcode = IORING_OP_SEND;
        if s.is_fixed {
            sqe.fd = s.fixed_index as i32;
            sqe.flags = IOSQE_FIXED_FILE;
        } else {
            sqe.fd = s.fd;
        }
        sqe.addr = unsafe { s.pending_write.as_ptr().add(s.write_offset) } as u64;
        sqe.len = (s.pending_write.len() - s.write_offset) as u32;
        sqe.user_data = ud(slot_idx, s.gen);
        s.send_inflight = true;
        true
    }

    /// Prepares send SQEs for all pending replies into the io_uring SQ ring.
    /// Returns the number of SQEs queued.
    pub fn prepare_sends(&mut self, ring: &mut IoUringInstance, conn_table: &mut ConnTable, ud: SendUd) -> usize {
        let mut queued = 0;

        // Retry connections that could not get an SQE last time.
        let stalled = std::mem::take(&mut self.stalled);
        for conn in stalled {
            let Some(s) = conn_table.validate_mut(&conn) else { continue };
            if s.send_inflight || s.closing || s.write_offset >= s.pending_write.len() {
                continue;
            }
            if Self::submit_send(ring, conn_table, conn.slot, ud) {
                queued += 1;
            } else {
                self.stalled.push(conn);
            }
        }

        for reply in self.pending_replies.drain(..) {
            let slot = match conn_table.validate_mut(&reply.conn) {
                Some(s) if !s.closing => s,
                _ => continue, // Stale or closing connection, discard
            };
            if reply.close {
                slot.keepalive = false;
            }
            // A send is in flight (or parked): never touch its buffer, queue behind it.
            if slot.send_inflight || slot.write_offset < slot.pending_write.len() {
                slot.queued_write.extend_from_slice(&reply.bytes);
                continue;
            }
            slot.pending_write = reply.bytes;
            slot.write_offset = 0;
            if Self::submit_send(ring, conn_table, reply.conn.slot, ud) {
                queued += 1;
            } else {
                self.stalled.push(reply.conn);
            }
        }

        queued
    }

    /// Handles a CQE for an IORING_OP_SEND operation of (slot_idx, gen24).
    /// Advances partial writes, starts queued replies, and says whether to close.
    pub fn handle_send_completion(
        &mut self,
        ring: &mut IoUringInstance,
        slot_idx: u32,
        gen24: u32,
        res: i32,
        conn_table: &mut ConnTable,
        ud: SendUd,
    ) -> SendOutcome {
        let s = match conn_table.slots.get_mut(slot_idx as usize) {
            Some(s) if s.in_use && (s.gen & crate::net::conn::GEN_MASK) == gen24 => s,
            _ => return SendOutcome::Keep, // stale CQE of an earlier connection in this slot
        };
        s.send_inflight = false;
        if s.closing || res < 0 {
            return SendOutcome::Close;
        }

        s.write_offset += res as usize;
        if s.write_offset >= s.pending_write.len() {
            // This buffer is done. Start the replies that queued up behind it, if any.
            s.pending_write.clear();
            s.write_offset = 0;
            if s.queued_write.is_empty() {
                return if s.keepalive { SendOutcome::Keep } else { SendOutcome::Close };
            }
            std::mem::swap(&mut s.pending_write, &mut s.queued_write);
        }
        // Partial send or newly swapped-in data: send the rest.
        let gen = s.gen;
        if !Self::submit_send(ring, conn_table, slot_idx, ud) {
            self.stalled.push(ConnRef { reactor: conn_table.reactor_id, slot: slot_idx, gen });
        }
        SendOutcome::Keep
    }
}
