//! Article slugs. SPEC.md defines `SLUGIFY(x)` as `trim(both '-' from lower(regexp_replace(x, '[^A-Za-z0-9]+', '-',
//! 'g')))` and says computing it outside SQL is fine "if it comes out byte-identical". Working on bytes gives the
//! same result as the regular expression on characters: every byte of a multi-byte character is outside
//! `[A-Za-z0-9]`, so a run of such characters collapses to one `-` either way.

/// The slug without its `-<id>` suffix.
pub fn slugify(title: &str) -> String {
    let mut out = String::with_capacity(title.len());
    let mut pending_dash = false;
    for &byte in title.as_bytes() {
        if byte.is_ascii_alphanumeric() {
            // A dash is only written between two alphanumeric runs: leading and trailing ones are trimmed.
            if pending_dash && !out.is_empty() {
                out.push('-');
            }
            pending_dash = false;
            out.push(byte.to_ascii_lowercase() as char);
        } else {
            pending_dash = true;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::slugify;

    #[test]
    fn matches_the_sql_definition() {
        assert_eq!(slugify("Hello, World!"), "hello-world");
        assert_eq!(slugify("  --Rust & Postgres--  "), "rust-postgres");
        assert_eq!(slugify("a"), "a");
        assert_eq!(slugify("Ünïcödé títle"), "n-c-d-t-tle");
        assert_eq!(slugify("日本語"), "");
        assert_eq!(slugify("Version 2.0"), "version-2-0");
        assert_eq!(slugify("!!!"), "");
        assert_eq!(slugify("UPPER lower 123"), "upper-lower-123");
    }
}
