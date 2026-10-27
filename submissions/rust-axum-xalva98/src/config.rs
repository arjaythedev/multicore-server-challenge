//! Process settings: names and defaults only. Every value comes from the environment at boot.

fn raw(key: &str) -> Option<String> {
    std::env::var(key).ok().map(|v| v.trim().to_string()).filter(|v| !v.is_empty())
}

pub fn env_string(key: &str, default: &str) -> String {
    raw(key).unwrap_or_else(|| default.to_string())
}

pub fn env_u32(key: &str, default: u32) -> u32 {
    raw(key).and_then(|v| v.parse().ok()).unwrap_or(default)
}

pub fn env_u64(key: &str, default: u64) -> u64 {
    raw(key).and_then(|v| v.parse().ok()).unwrap_or(default)
}

pub fn env_usize(key: &str, default: usize) -> usize {
    raw(key).and_then(|v| v.parse().ok()).filter(|n| *n > 0).unwrap_or(default)
}

pub fn env_opt_usize(key: &str) -> Option<usize> {
    raw(key).and_then(|v| v.parse().ok()).filter(|n| *n > 0)
}

pub fn cores() -> usize {
    std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1)
}
