//! Lifetime laundering for scratch vectors.
//!
//! A batch borrows its text from the `Results` arena and from the jobs' buffers, but the vectors that hold those
//! borrows must outlive the batch or they would be allocated again every time. [`recycle`] empties a vector of
//! borrows and hands its allocation back under a new lifetime: safe code, because it only moves the buffer of a
//! vector that holds no elements. (The standard library reuses the allocation when source and target element types
//! have the same layout, which they do here since only the lifetime differs; a test pins that.)

/// An empty `Vec<&str>` with the allocation of `v`, usable for any lifetime.
pub fn recycle<'b>(mut v: Vec<&str>) -> Vec<&'b str> {
    v.clear();
    v.into_iter().map(|_| "").collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_allocation_survives_a_change_of_lifetime() {
        let owner = String::from("alpha beta gamma");
        let mut v: Vec<&str> = Vec::with_capacity(64);
        v.extend(owner.split(' '));
        let pointer = v.as_ptr();
        let again: Vec<&str> = recycle(v);
        assert!(again.is_empty());
        assert_eq!(again.as_ptr(), pointer);
        assert!(again.capacity() >= 64);
    }
}
