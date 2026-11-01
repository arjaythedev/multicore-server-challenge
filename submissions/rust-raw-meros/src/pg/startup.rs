//! Connection start: startup message, authentication, parameter noise, up to the first ReadyForQuery.
//!
//! Supported authentication: trust (AuthenticationOk), cleartext password, SCRAM-SHA-256. MD5, GSS, SSPI and
//! SCRAM-SHA-256-PLUS are refused with `PgError::Auth`. The handshake runs once per connection, so it favours
//! clarity over allocation count.

use super::config::Config;
use super::error::PgError;
use super::scram::{self, ScramClient};
use super::transport::Transport;
use super::wire::{self, Payload, auth, tag};

/// Where the authentication exchange stands.
enum AuthState {
    /// Nothing requested yet.
    Pending,
    /// SCRAM client-first sent; waiting for server-first.
    ScramStarted(ScramClient),
    /// SCRAM client-final sent; waiting for server-final.
    ScramAwaitingFinal(ScramClient),
    /// SCRAM server signature checked; waiting for AuthenticationOk.
    ScramVerified,
    /// AuthenticationOk received.
    Authenticated,
}

pub(super) fn handshake(t: &mut Transport, cfg: &Config, options: &str) -> Result<(), PgError> {
    wire::encode_startup(&mut t.out, &cfg.user, &cfg.database, options)?;
    t.write_out()?;
    let mut state = AuthState::Pending;
    loop {
        let (msg_tag, payload) = t.read_message()?;
        match msg_tag {
            tag::AUTH => {
                // Copy: the reply below writes to `t`, which the borrowed payload still locks.
                let payload = payload.to_vec();
                state = on_auth_request(t, cfg, state, &payload)?;
            }
            tag::ERROR => return Err(PgError::Server(wire::parse_error_response(payload))),
            tag::READY_FOR_QUERY => {
                return match state {
                    AuthState::Authenticated => Ok(()),
                    _ => Err(PgError::protocol(
                        "ReadyForQuery before authentication finished",
                    )),
                };
            }
            // ParameterStatus, BackendKeyData, NoticeResponse: nothing in this client needs them.
            tag::PARAMETER_STATUS | tag::BACKEND_KEY_DATA | tag::NOTICE => {}
            other => {
                return Err(PgError::protocol(format!(
                    "unexpected message '{}' during startup",
                    other as char
                )));
            }
        }
    }
}

fn on_auth_request(
    t: &mut Transport,
    cfg: &Config,
    state: AuthState,
    payload: &[u8],
) -> Result<AuthState, PgError> {
    let mut p = Payload::new(payload);
    match (p.i32()?, state) {
        (auth::OK, AuthState::Pending | AuthState::ScramVerified) => Ok(AuthState::Authenticated),
        (auth::OK, _) => Err(PgError::Auth(
            "server accepted us before the SCRAM exchange finished".into(),
        )),
        (auth::CLEARTEXT_PASSWORD, AuthState::Pending) => {
            wire::encode_password(&mut t.out, require_password(cfg)?)?;
            t.write_out()?;
            Ok(AuthState::Pending)
        }
        (auth::SASL, AuthState::Pending) => {
            require_scram_mechanism(&mut p)?;
            require_password(cfg)?;
            let (client, first) = ScramClient::start_random(&cfg.user)?;
            wire::encode_sasl_initial(&mut t.out, scram::MECHANISM, &first)?;
            t.write_out()?;
            Ok(AuthState::ScramStarted(client))
        }
        (auth::SASL_CONTINUE, AuthState::ScramStarted(mut client)) => {
            let reply = client.respond(p.rest(), require_password(cfg)?.as_bytes())?;
            wire::encode_sasl_response(&mut t.out, &reply)?;
            t.write_out()?;
            Ok(AuthState::ScramAwaitingFinal(client))
        }
        (auth::SASL_FINAL, AuthState::ScramAwaitingFinal(client)) => {
            client.verify(p.rest())?;
            Ok(AuthState::ScramVerified)
        }
        (code, _) => Err(PgError::Auth(format!(
            "unsupported or unexpected authentication request {code}"
        ))),
    }
}

fn require_password(cfg: &Config) -> Result<&str, PgError> {
    cfg.password
        .as_deref()
        .ok_or_else(|| PgError::Auth("server asks for a password but the url has none".into()))
}

/// The SASL request lists the mechanisms the server offers as NUL-terminated names, ended by an empty name.
fn require_scram_mechanism(p: &mut Payload<'_>) -> Result<(), PgError> {
    let mut seen = Vec::new();
    loop {
        let name = p.cstr()?;
        if name.is_empty() {
            return Err(PgError::Auth(format!(
                "server offers no SCRAM-SHA-256 (offered: {})",
                String::from_utf8_lossy(&seen.join(&b' '))
            )));
        }
        if name == scram::MECHANISM.as_bytes() {
            return Ok(());
        }
        seen.push(name);
    }
}
