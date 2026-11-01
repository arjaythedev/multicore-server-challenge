//! The `Authorization: Token <jwt>` header (SPEC.md "Authentication").

use crate::jwt::Jwt;

/// What the header says about the caller.
#[derive(Debug, PartialEq, Eq)]
pub enum Auth<'a> {
    /// No header: the viewer is user 0.
    Anonymous,
    /// A valid token of this user; `token` is the JWT as presented (GET/PUT /api/user echo it).
    User { id: i64, token: &'a [u8] },
    /// A header that is present but not a valid, unexpired HS256 token of the `Token` scheme: 401.
    Invalid,
}

const SCHEME: &[u8] = b"Token ";

/// Checks signature and `exp` on every call: there is no verification cache.
pub fn authenticate<'a>(jwt: &Jwt, header: Option<&'a [u8]>, now_seconds: u64) -> Auth<'a> {
    let Some(value) = header else {
        return Auth::Anonymous;
    };
    let Some(token) = value.strip_prefix(SCHEME) else {
        return Auth::Invalid;
    };
    match jwt.verify(token, now_seconds) {
        Ok(id) if id <= i64::MAX as u64 && id != 0 => Auth::User {
            id: id as i64,
            token,
        },
        _ => Auth::Invalid,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn token(jwt: &Jwt, id: u64, exp: u64) -> Vec<u8> {
        let mut out = b"Token ".to_vec();
        jwt.sign(id, 1_000, exp, &mut out);
        out
    }

    #[test]
    fn no_header_is_anonymous() {
        assert_eq!(authenticate(&Jwt::new(b"k"), None, 5), Auth::Anonymous);
    }

    #[test]
    fn valid_token_gives_the_user() {
        let jwt = Jwt::new(b"k");
        let header = token(&jwt, 42, 2_000);
        match authenticate(&jwt, Some(&header), 1_500) {
            Auth::User { id, token } => {
                assert_eq!(id, 42);
                assert!(token.starts_with(b"eyJ"));
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn wrong_scheme_wrong_key_and_expired_are_invalid() {
        let jwt = Jwt::new(b"k");
        let header = token(&jwt, 42, 2_000);
        let bearer: Vec<u8> = [b"Bearer ".as_slice(), &header[6..]].concat();
        assert_eq!(authenticate(&jwt, Some(&bearer), 1_500), Auth::Invalid);
        assert_eq!(
            authenticate(&Jwt::new(b"other"), Some(&header), 1_500),
            Auth::Invalid
        );
        assert_eq!(authenticate(&jwt, Some(&header), 2_000), Auth::Invalid);
        assert_eq!(authenticate(&jwt, Some(b"Token"), 1_500), Auth::Invalid);
        assert_eq!(
            authenticate(&jwt, Some(&token(&jwt, 0, 2_000)), 1_500),
            Auth::Invalid
        );
    }
}
