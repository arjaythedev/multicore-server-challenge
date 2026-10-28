//! SCRAM-SHA-256 client (RFC 5802 / RFC 7677) as Postgres uses it, without channel binding.
//!
//! Three steps, each a pure function of its inputs so the RFC test vector can pin them:
//! [`ScramClient::start`] builds client-first, [`ScramClient::respond`] turns server-first into client-final,
//! [`ScramClient::verify`] checks the server's signature (proving the server also knows the password).
//!
//! Not handled: `SCRAM-SHA-256-PLUS` (no TLS here), SASLprep of the password (passwords are used as raw UTF-8,
//! which is identical for ASCII and for what Postgres itself does when SASLprep leaves a string unchanged),
//! username in the message (Postgres ignores it and takes the startup user).

use super::error::PgError;
use crate::crypto::{base64, ct, hmac::HmacSha256, pbkdf2::pbkdf2_hmac_sha256, random, sha256};

/// Mechanism name sent in `SASLInitialResponse`.
pub(super) const MECHANISM: &str = "SCRAM-SHA-256";
/// GS2 header without channel binding; base64 of it (`biws`) is the `c=` attribute of client-final.
const GS2_HEADER: &str = "n,,";
const CHANNEL_BINDING_B64: &str = "biws";
/// Random bytes in the client nonce (base64 encoded to 24 characters).
const NONCE_BYTES: usize = 18;
/// Upper bound on the server's PBKDF2 iterations. Postgres defaults to 4096; this stops a hostile server from
/// pinning a CPU for minutes.
const MAX_ITERATIONS: u32 = 1 << 24;

fn auth_err(msg: &str) -> PgError {
    PgError::Auth(format!("SCRAM: {msg}"))
}

pub(super) struct ScramClient {
    client_nonce: String,
    client_first_bare: String,
    /// Set by `respond`; the signature the server must present in its final message.
    expected_server_signature: Option<[u8; 32]>,
}

impl ScramClient {
    /// Builds the client-first message for `user` with an explicit nonce (tests) and returns it with the state.
    pub fn start(user: &str, client_nonce: &str) -> (Self, Vec<u8>) {
        let client_first_bare = format!("n={},r={client_nonce}", escape_username(user));
        let message = format!("{GS2_HEADER}{client_first_bare}").into_bytes();
        let state = ScramClient {
            client_nonce: client_nonce.to_owned(),
            client_first_bare,
            expected_server_signature: None,
        };
        (state, message)
    }

    /// Like [`start`](Self::start) with a fresh random nonce from the OS.
    pub fn start_random(user: &str) -> Result<(Self, Vec<u8>), PgError> {
        let mut raw = [0u8; NONCE_BYTES];
        random::fill(&mut raw)?;
        let mut nonce = Vec::with_capacity(NONCE_BYTES * 4 / 3 + 4);
        base64::encode(&raw, &mut nonce);
        // Base64 output is ASCII; the standard alphabet never contains ','.
        let nonce = String::from_utf8(nonce).map_err(|_| auth_err("nonce is not ASCII"))?;
        Ok(Self::start(user, &nonce))
    }

    /// Consumes server-first (`r=<nonce>,s=<salt>,i=<count>`) and returns client-final.
    pub fn respond(&mut self, server_first: &[u8], password: &[u8]) -> Result<Vec<u8>, PgError> {
        let server_first =
            std::str::from_utf8(server_first).map_err(|_| auth_err("server-first is not UTF-8"))?;
        let ServerFirst {
            nonce,
            salt,
            iterations,
        } = parse_server_first(server_first)?;
        if !nonce.starts_with(&self.client_nonce) || nonce.len() == self.client_nonce.len() {
            return Err(auth_err("server nonce does not extend the client nonce"));
        }
        let salted = pbkdf2_hmac_sha256(password, &salt, iterations);
        let client_key = HmacSha256::new(&salted).mac(&[b"Client Key"]);
        let stored_key = sha256::digest(&client_key);
        let client_final_without_proof = format!("c={CHANNEL_BINDING_B64},r={nonce}");
        let auth_message = format!(
            "{},{server_first},{client_final_without_proof}",
            self.client_first_bare
        );

        let client_signature = HmacSha256::new(&stored_key).mac(&[auth_message.as_bytes()]);
        let mut proof = client_key;
        proof
            .iter_mut()
            .zip(client_signature)
            .for_each(|(p, s)| *p ^= s);

        let server_key = HmacSha256::new(&salted).mac(&[b"Server Key"]);
        self.expected_server_signature =
            Some(HmacSha256::new(&server_key).mac(&[auth_message.as_bytes()]));

        let mut out = client_final_without_proof.into_bytes();
        out.extend_from_slice(b",p=");
        base64::encode(&proof, &mut out);
        Ok(out)
    }

    /// Checks server-final (`v=<signature>`). An `e=<reason>` reply is the server rejecting the proof.
    pub fn verify(&self, server_final: &[u8]) -> Result<(), PgError> {
        let expected = self
            .expected_server_signature
            .ok_or_else(|| auth_err("server-final before client-final"))?;
        let text =
            std::str::from_utf8(server_final).map_err(|_| auth_err("server-final is not UTF-8"))?;
        if let Some(reason) = text.strip_prefix("e=") {
            return Err(auth_err(&format!("server rejected the proof: {reason}")));
        }
        let encoded = text
            .strip_prefix("v=")
            .ok_or_else(|| auth_err("server-final has no signature"))?;
        let signature =
            base64::decode(encoded.as_bytes()).ok_or_else(|| auth_err("bad signature encoding"))?;
        if ct::eq(&signature, &expected) {
            Ok(())
        } else {
            Err(auth_err("server signature mismatch"))
        }
    }
}

struct ServerFirst<'a> {
    nonce: &'a str,
    salt: Vec<u8>,
    iterations: u32,
}

fn parse_server_first(text: &str) -> Result<ServerFirst<'_>, PgError> {
    let (mut nonce, mut salt, mut iterations) = (None, None, None);
    for attr in text.split(',') {
        match attr.split_once('=') {
            Some(("r", v)) => nonce = Some(v),
            Some(("s", v)) => {
                salt = Some(
                    base64::decode(v.as_bytes()).ok_or_else(|| auth_err("bad salt encoding"))?,
                )
            }
            Some(("i", v)) => {
                iterations = Some(
                    v.parse::<u32>()
                        .map_err(|_| auth_err("bad iteration count"))?,
                )
            }
            Some(("m", _)) => return Err(auth_err("unsupported mandatory extension")),
            _ => {}
        }
    }
    let iterations = iterations.ok_or_else(|| auth_err("server-first lacks i="))?;
    if iterations == 0 || iterations > MAX_ITERATIONS {
        return Err(auth_err("iteration count out of range"));
    }
    Ok(ServerFirst {
        nonce: nonce.ok_or_else(|| auth_err("server-first lacks r="))?,
        salt: salt.ok_or_else(|| auth_err("server-first lacks s="))?,
        iterations,
    })
}

/// RFC 5802: `=` and `,` in a user name are written `=3D` and `=2C`.
fn escape_username(user: &str) -> String {
    user.replace('=', "=3D").replace(',', "=2C")
}

#[cfg(test)]
mod tests {
    use super::*;

    // RFC 7677 section 3 example (user "user", password "pencil").
    const NONCE: &str = "rOprNGfwEbeRWgbNEkqO";
    const SERVER_FIRST: &str =
        "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096";
    const CLIENT_FINAL: &str = "c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=";
    const SERVER_FINAL: &str = "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=";

    #[test]
    fn rfc7677_vector() {
        let (mut client, first) = ScramClient::start("user", NONCE);
        assert_eq!(first, b"n,,n=user,r=rOprNGfwEbeRWgbNEkqO");
        let final_msg = client.respond(SERVER_FIRST.as_bytes(), b"pencil").unwrap();
        assert_eq!(String::from_utf8(final_msg).unwrap(), CLIENT_FINAL);
        client.verify(SERVER_FINAL.as_bytes()).unwrap();
    }

    #[test]
    fn wrong_server_signature_is_rejected() {
        let (mut client, _) = ScramClient::start("user", NONCE);
        client.respond(SERVER_FIRST.as_bytes(), b"pencil").unwrap();
        let forged = "v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G5=";
        assert!(client.verify(forged.as_bytes()).is_err());
        assert!(client.verify(b"v=").is_err());
        assert!(client.verify(b"e=invalid-proof").is_err());
        assert!(client.verify(b"x=1").is_err());
    }

    #[test]
    fn wrong_password_fails_verification() {
        let (mut client, _) = ScramClient::start("user", NONCE);
        client.respond(SERVER_FIRST.as_bytes(), b"wrong").unwrap();
        assert!(client.verify(SERVER_FINAL.as_bytes()).is_err());
    }

    #[test]
    fn verify_before_respond_fails() {
        let (client, _) = ScramClient::start("user", NONCE);
        assert!(client.verify(SERVER_FINAL.as_bytes()).is_err());
    }

    #[test]
    fn hostile_server_first_is_rejected() {
        let try_first = |s: &str| {
            ScramClient::start("u", NONCE)
                .0
                .respond(s.as_bytes(), b"p")
                .is_err()
        };
        assert!(
            try_first("r=otherNonce,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"),
            "foreign nonce"
        );
        assert!(
            try_first("r=rOprNGfwEbeRWgbNEkqO,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"),
            "nonce not extended"
        );
        assert!(
            try_first("r=rOprNGfwEbeRWgbNEkqOx,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=0"),
            "zero iterations"
        );
        assert!(
            try_first("r=rOprNGfwEbeRWgbNEkqOx,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4000000000"),
            "huge iterations"
        );
        assert!(
            try_first("r=rOprNGfwEbeRWgbNEkqOx,s=!!!,i=4096"),
            "bad salt"
        );
        assert!(try_first("r=rOprNGfwEbeRWgbNEkqOx,i=4096"), "no salt");
        assert!(
            try_first("r=rOprNGfwEbeRWgbNEkqOx,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=abc"),
            "bad count"
        );
        assert!(
            try_first("m=x,r=rOprNGfwEbeRWgbNEkqOx,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096"),
            "mandatory extension"
        );
    }

    #[test]
    fn username_escaping_and_random_nonce() {
        assert_eq!(escape_username("a=b,c"), "a=3Db=2Cc");
        let (_, first) = ScramClient::start_random("u").unwrap();
        let (_, second) = ScramClient::start_random("u").unwrap();
        assert_ne!(first, second);
        assert!(first.starts_with(b"n,,n=u,r="));
    }
}
