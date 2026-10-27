//! RFC 3339 in UTC with exactly three fractional digits, truncated: `2025-04-01T12:00:00.000Z`.

use std::fmt;

use serde::Serializer;
use time::{OffsetDateTime, UtcOffset};

struct Millis(OffsetDateTime);

impl fmt::Display for Millis {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let t = self.0.to_offset(UtcOffset::UTC);
        write!(
            f,
            "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:03}Z",
            t.year(),
            u8::from(t.month()),
            t.day(),
            t.hour(),
            t.minute(),
            t.second(),
            t.millisecond()
        )
    }
}

pub fn serialize<S: Serializer>(t: &OffsetDateTime, s: S) -> Result<S::Ok, S::Error> {
    s.collect_str(&Millis(*t))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn microseconds_are_cut_never_rounded() {
        let t = OffsetDateTime::from_unix_timestamp_nanos(1_743_508_800_999_999_000).unwrap();
        assert_eq!(Millis(t).to_string(), "2025-04-01T12:00:00.999Z");
        let offset = t.to_offset(UtcOffset::from_hms(2, 0, 0).unwrap());
        assert_eq!(Millis(offset).to_string(), "2025-04-01T12:00:00.999Z");
    }
}
