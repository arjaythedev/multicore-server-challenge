//! Fast bump arena allocator for batch query processing and response rendering.
//! O(1) allocation, O(1) batch reset, zero per-object malloc/free overhead.

use std::alloc::{alloc, dealloc, Layout};
use std::ptr::NonNull;

pub struct BatchArena {
    ptr: NonNull<u8>,
    capacity: usize,
    offset: usize,
}

impl BatchArena {
    pub fn new(capacity: usize) -> Self {
        assert!(capacity > 0);
        let layout = Layout::from_size_align(capacity, 64).expect("invalid layout");
        let raw = unsafe { alloc(layout) };
        let ptr = NonNull::new(raw).expect("out of memory for arena");

        Self {
            ptr,
            capacity,
            offset: 0,
        }
    }

    #[inline(always)]
    pub fn alloc_bytes(&mut self, len: usize) -> Option<&mut [u8]> {
        // Align to 8 bytes
        let aligned_offset = (self.offset + 7) & !7;
        if aligned_offset + len > self.capacity {
            return None;
        }

        unsafe {
            let slice_ptr = self.ptr.as_ptr().add(aligned_offset);
            self.offset = aligned_offset + len;
            Some(std::slice::from_raw_parts_mut(slice_ptr, len))
        }
    }

    #[inline(always)]
    pub fn alloc_str<'a>(&'a mut self, s: &str) -> Option<&'a mut str> {
        let bytes = self.alloc_bytes(s.len())?;
        bytes.copy_from_slice(s.as_bytes());
        unsafe { Some(std::str::from_utf8_unchecked_mut(bytes)) }
    }

    #[inline(always)]
    pub fn reset(&mut self) {
        self.offset = 0;
    }

    #[inline(always)]
    pub fn used(&self) -> usize {
        self.offset
    }

    #[inline(always)]
    pub fn capacity(&self) -> usize {
        self.capacity
    }
}

impl Drop for BatchArena {
    fn drop(&mut self) {
        let layout = Layout::from_size_align(self.capacity, 64).expect("invalid layout");
        unsafe {
            dealloc(self.ptr.as_ptr(), layout);
        }
    }
}
