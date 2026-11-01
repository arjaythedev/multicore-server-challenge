//! Batching: turn a list of jobs into lockstep runs of at most [`MAX_LANES`] lanes.
//!
//! Choice for mixed costs: jobs are grouped by cost (the lanes of one run must execute the same number of
//! rounds), each group is split into as few, as equal chunks as possible (7 jobs run as 4 + 3, not 6 + 1, which is
//! measurably faster), and a chunk of `k` jobs runs with exactly `k` lanes, so a lone job takes the plain
//! single-lane path. Results come back in the order of the input.

use super::eks::{DIGEST_BYTES, digest};

/// Most hashes computed together. Six lanes (24 KiB of S-boxes) still fit in L1.
pub const MAX_LANES: usize = 6;

/// One hash to compute.
#[derive(Debug, Clone, Copy)]
pub struct HashJob<'a> {
    pub password: &'a [u8],
    pub salt: [u8; 16],
    pub cost: u32,
}

/// Raw 23-byte digests for all jobs, in input order.
pub fn hash_many(jobs: &[HashJob]) -> Vec<[u8; DIGEST_BYTES]> {
    let mut by_cost: Vec<usize> = (0..jobs.len()).collect();
    by_cost.sort_by_key(|&i| jobs[i].cost); // stable: equal costs keep input order
    let mut out = vec![[0u8; DIGEST_BYTES]; jobs.len()];
    let mut start = 0;
    while start < by_cost.len() {
        let cost = jobs[by_cost[start]].cost;
        let same_cost = by_cost[start..]
            .iter()
            .take_while(|&&i| jobs[i].cost == cost)
            .count();
        let mut group = &by_cost[start..start + same_cost];
        for size in balanced_chunk_sizes(same_cost) {
            let (chunk, rest) = group.split_at(size);
            run_chunk(jobs, chunk, &mut out);
            group = rest;
        }
        start += same_cost;
    }
    out
}

/// Splits `n` jobs into `ceil(n / MAX_LANES)` chunks whose sizes differ by at most one (larger ones first).
fn balanced_chunk_sizes(n: usize) -> impl Iterator<Item = usize> {
    let chunks = n.div_ceil(MAX_LANES);
    (0..chunks).map(move |i| n / chunks + usize::from(i < n % chunks))
}

/// Runs `chunk` (1..=MAX_LANES indices, one cost) with exactly that many lanes and stores the digests.
fn run_chunk(jobs: &[HashJob], chunk: &[usize], out: &mut [[u8; DIGEST_BYTES]]) {
    match chunk.len() {
        1 => run_lanes::<1>(jobs, chunk, out),
        2 => run_lanes::<2>(jobs, chunk, out),
        3 => run_lanes::<3>(jobs, chunk, out),
        4 => run_lanes::<4>(jobs, chunk, out),
        5 => run_lanes::<5>(jobs, chunk, out),
        6 => run_lanes::<6>(jobs, chunk, out),
        n => unreachable!("chunks are 1..={MAX_LANES} long, got {n}"),
    }
}

fn run_lanes<const N: usize>(jobs: &[HashJob], chunk: &[usize], out: &mut [[u8; DIGEST_BYTES]]) {
    let passwords: [&[u8]; N] = std::array::from_fn(|i| jobs[chunk[i]].password);
    let salts: [[u8; 16]; N] = std::array::from_fn(|i| jobs[chunk[i]].salt);
    let digests = digest::<N>(passwords, &salts, jobs[chunk[0]].cost);
    for (&index, d) in chunk.iter().zip(digests) {
        out[index] = d;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chunk_sizes_are_balanced_and_bounded() {
        for n in 1..=40 {
            let sizes: Vec<usize> = balanced_chunk_sizes(n).collect();
            assert_eq!(sizes.iter().sum::<usize>(), n);
            assert!(sizes.iter().all(|&s| (1..=MAX_LANES).contains(&s)));
            assert!(sizes.iter().max().unwrap() - sizes.iter().min().unwrap() <= 1);
        }
        assert_eq!(balanced_chunk_sizes(7).collect::<Vec<_>>(), [4, 3]);
        assert_eq!(balanced_chunk_sizes(1).collect::<Vec<_>>(), [1]);
        assert_eq!(balanced_chunk_sizes(0).count(), 0);
    }
}
