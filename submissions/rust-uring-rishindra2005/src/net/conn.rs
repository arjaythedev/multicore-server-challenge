//! Connection slot management and direct descriptor tracking.
//! Generates and validates `ConnRef { reactor, slot, gen }` to prevent stale operations.

use std::os::unix::io::RawFd;
use crate::types::ConnRef;

/// Bits of the slot generation carried in io_uring user_data (see net::make_user_data).
pub const GEN_MASK: u32 = 0x00FF_FFFF;

pub struct ConnSlot {
    pub fd: RawFd,
    pub fixed_index: u32,
    pub is_fixed: bool,
    pub gen: u32,
    pub in_use: bool,
    pub keepalive: bool,

    // Streaming partial read buffer across multishot packets
    pub partial_read: Vec<u8>,

    // Outgoing write buffer the kernel is (or will be) sending. Never touched while `send_inflight`.
    pub pending_write: Vec<u8>,
    pub write_offset: usize,
    /// Replies that arrived while a send was in flight; swapped into `pending_write` when it completes.
    pub queued_write: Vec<u8>,
    /// A SEND SQE for `pending_write` is with the kernel (its buffer must stay alive and unmodified).
    pub send_inflight: bool,
    /// Close requested while a send was in flight; finished when that send's CQE arrives.
    pub closing: bool,
}

impl Default for ConnSlot {
    fn default() -> Self {
        Self {
            fd: -1,
            fixed_index: 0,
            is_fixed: false,
            gen: 0,
            in_use: false,
            keepalive: true,
            partial_read: Vec::new(),
            pending_write: Vec::new(),
            write_offset: 0,
            queued_write: Vec::new(),
            send_inflight: false,
            closing: false,
        }
    }
}

pub struct ConnTable {
    pub reactor_id: u8,
    pub slots: Vec<ConnSlot>,
    pub free_slots: Vec<u32>,
}

impl ConnTable {
    pub fn new(reactor_id: u8, capacity: usize) -> Self {
        Self {
            reactor_id,
            slots: Vec::with_capacity(capacity),
            free_slots: Vec::with_capacity(capacity / 4),
        }
    }

    pub fn allocate(&mut self, fd: RawFd, fixed_index: u32, is_fixed: bool) -> (u32, ConnRef) {
        let (slot_idx, gen) = if let Some(idx) = self.free_slots.pop() {
            let s = &mut self.slots[idx as usize];
            s.fd = fd;
            s.fixed_index = fixed_index;
            s.is_fixed = is_fixed;
            s.gen = s.gen.wrapping_add(1);
            s.in_use = true;
            s.keepalive = true;
            s.partial_read.clear();
            s.pending_write.clear();
            s.write_offset = 0;
            s.queued_write.clear();
            s.send_inflight = false;
            s.closing = false;
            (idx, s.gen)
        } else {
            let idx = self.slots.len() as u32;
            let s = ConnSlot {
                fd,
                fixed_index,
                is_fixed,
                gen: 1,
                in_use: true,
                keepalive: true,
                partial_read: Vec::new(),
                pending_write: Vec::new(),
                write_offset: 0,
                queued_write: Vec::new(),
                send_inflight: false,
                closing: false,
            };
            self.slots.push(s);
            (idx, 1)
        };

        let conn_ref = ConnRef {
            reactor: self.reactor_id,
            slot: slot_idx,
            gen,
        };

        (slot_idx, conn_ref)
    }

    #[inline(always)]
    pub fn get_slot(&self, slot_idx: u32) -> Option<&ConnSlot> {
        self.slots.get(slot_idx as usize)
    }

    #[inline(always)]
    pub fn get_slot_mut(&mut self, slot_idx: u32) -> Option<&mut ConnSlot> {
        self.slots.get_mut(slot_idx as usize)
    }

    #[inline(always)]
    pub fn validate(&self, conn: &ConnRef) -> Option<&ConnSlot> {
        if conn.reactor != self.reactor_id {
            return None;
        }
        let slot = self.slots.get(conn.slot as usize)?;
        if slot.in_use && slot.gen == conn.gen {
            Some(slot)
        } else {
            None
        }
    }

    #[inline(always)]
    pub fn validate_mut(&mut self, conn: &ConnRef) -> Option<&mut ConnSlot> {
        if conn.reactor != self.reactor_id {
            return None;
        }
        let slot = self.slots.get_mut(conn.slot as usize)?;
        if slot.in_use && slot.gen == conn.gen {
            Some(slot)
        } else {
            None
        }
    }

    /// True if a CQE tagged with (slot_idx, gen24) still belongs to the live connection in that slot.
    #[inline(always)]
    pub fn is_live(&self, slot_idx: u32, gen24: u32) -> bool {
        match self.slots.get(slot_idx as usize) {
            Some(s) => s.in_use && !s.closing && (s.gen & GEN_MASK) == gen24,
            None => false,
        }
    }

    pub fn release(&mut self, slot_idx: u32) -> (RawFd, u32, bool) {
        if let Some(s) = self.slots.get_mut(slot_idx as usize) {
            if s.in_use {
                let fd = s.fd;
                let fixed = s.fixed_index;
                let is_fixed = s.is_fixed;

                s.fd = -1;
                s.in_use = false;
                s.partial_read.clear();
                s.pending_write.clear();
                s.write_offset = 0;
                s.queued_write.clear();
                s.send_inflight = false;
                s.closing = false;
                self.free_slots.push(slot_idx);

                return (fd, fixed, is_fixed);
            }
        }
        (-1, 0, false)
    }
}
