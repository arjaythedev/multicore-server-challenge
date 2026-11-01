//! Unit tests for the JWT verifier: Python-minted vectors, rejection cases, boundaries, both code paths.

use super::*;

const SECRET: &[u8] = b"multicore-server-challenge";
const NOW: u64 = 1_700_000_100;
const EXP: u64 = 1_702_592_000;

// Tokens minted with Python (hmac + base64) for SECRET; payloads in the comments.
/// {"sub":"42","iat":1700000000,"exp":1702592000}, the load generator's layout.
const TOKEN_LOADGEN: &str = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI0MiIsImlhdCI6MTcwMDAwMDAwMCwiZXhwIjoxNzAyNTkyMDAwfQ.F8UVd1Q3KoSndSmq2NiX__v-D_NukaXxuFa-IFqmz-0";
/// {"exp":1702592000,"iat":1700000000,"sub":"42"}, golang-jwt MapClaims (alphabetical).
const TOKEN_ALPHABETICAL: &str = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE3MDI1OTIwMDAsImlhdCI6MTcwMDAwMDAwMCwic3ViIjoiNDIifQ.Ecbk3Icv8PTbXUsa-ljQ4CsKwS9QiboVsWLp5W3kOMQ";
/// { "sub" : "7" , "iat":1, "exp":1702592000, "x":"y" }
const TOKEN_SPACED_EXTRA: &str = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyAic3ViIiA6ICI3IiAsICJpYXQiOjEsICJleHAiOjE3MDI1OTIwMDAsICJ4IjoieSIgfQ.Ibo9Vr3GE1h1JjuxkGtOhQhedTvjQ6rlGV2hXUpee5w";
/// {"sub":"42","iat":1,"exp":1702592000}
const TOKEN_ESCAPES: &str = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzXHUwMDc1YiI6IjRcdTAwMzIiLCJpYXQiOjEsImV4cCI6MTcwMjU5MjAwMH0.jNkDkBZc4DxBmutyglFq1WcKJdSW2ORdd6ZMzWjR52s";
/// header {"typ":"JWT","alg":"HS256"}, payload in the loadgen layout with sub 42, iat 1.
const TOKEN_REORDERED_HEADER: &str = "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJzdWIiOiI0MiIsImlhdCI6MSwiZXhwIjoxNzAyNTkyMDAwfQ.VXTjr3toPHK_T3gFj0bNQ6ioGpE3WBeK9p7uT_Ap46w";
/// header {"alg":"none","typ":"JWT"}, empty signature.
const TOKEN_ALG_NONE: &str =
    "eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0.eyJzdWIiOiI0MiIsImlhdCI6MSwiZXhwIjoxNzAyNTkyMDAwfQ.";
/// header {"alg":"HS512",...}, signed with HMAC-SHA-512.
const TOKEN_HS512: &str = "eyJhbGciOiJIUzUxMiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI0MiIsImlhdCI6MSwiZXhwIjoxNzAyNTkyMDAwfQ.cueoYNJR0yo60RDSm79fLcutbm_Ml_NYNfwIfWBQM5rtUOZANWJp1KaasOQXwKhCnATgbl47iQrf9Oo9_yPGcw";
/// {"sub":"42","iat":1}
const TOKEN_NO_EXP: &str = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI0MiIsImlhdCI6MX0.M6Sc6LDXAGV1NmDEL0AoqkOTeGtKcDxT0lC5XFXvZv0";
/// {"sub":"abc","iat":1,"exp":1702592000}
const TOKEN_SUB_LETTERS: &str = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiJhYmMiLCJpYXQiOjEsImV4cCI6MTcwMjU5MjAwMH0.yGFrd_fHtTfJyIbsnUd6ybzbVKiJ2FHbxdAoQCKevZs";
/// {"sub":"99999999999999999999999","iat":1,"exp":1702592000}
const TOKEN_SUB_HUGE: &str = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI5OTk5OTk5OTk5OTk5OTk5OTk5OTk5OSIsImlhdCI6MSwiZXhwIjoxNzAyNTkyMDAwfQ.K4_1RxmHl4m6F4paGFuOqNEbyrMRkTH6fF4lN8MODzs";
/// {"sub":"42","iat":1,"exp":1.7e9}
const TOKEN_EXP_FLOAT: &str = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiI0MiIsImlhdCI6MSwiZXhwIjoxLjdlOX0.9UV4LqmvzJga3LiicDeMtcqLprS9pBr2-2bRMtVlSRI";
/// {"sub":42,"iat":1,"exp":1702592000}
const TOKEN_SUB_NUMBER: &str = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOjQyLCJpYXQiOjEsImV4cCI6MTcwMjU5MjAwMH0.NdXDl7K1Zrj-T-MUO5QEzqJ6BgDfpZ2V5y2zN1_m6aI";

fn jwt() -> Jwt {
    Jwt::new(SECRET)
}

fn verify(token: &str) -> Result<u64, JwtError> {
    jwt().verify(token.as_bytes(), NOW)
}

/// Builds a correctly signed token from raw header and payload JSON.
fn mint(header: &str, payload: &str) -> String {
    let mut text = Vec::new();
    base64::encode_url(header.as_bytes(), &mut text);
    text.push(b'.');
    base64::encode_url(payload.as_bytes(), &mut text);
    let signature = HmacSha256::new(SECRET).mac(&[&text]);
    text.push(b'.');
    base64::encode_url(&signature, &mut text);
    String::from_utf8(text).unwrap()
}

const HEADER_JSON: &[u8] = br#"{"alg":"HS256","typ":"JWT"}"#;
const HEADER: &str = r#"{"alg":"HS256","typ":"JWT"}"#;

fn mint_claims(payload: &str) -> String {
    mint(HEADER, payload)
}

#[test]
fn header_constant_matches_header_json() {
    let mut encoded = Vec::new();
    base64::encode_url(HEADER_JSON, &mut encoded);
    assert_eq!(encoded, HEADER_B64);
}

#[test]
fn accepts_tokens_from_other_minters() {
    assert_eq!(verify(TOKEN_LOADGEN), Ok(42));
    assert_eq!(verify(TOKEN_ALPHABETICAL), Ok(42));
    assert_eq!(verify(TOKEN_SPACED_EXTRA), Ok(7));
    assert_eq!(verify(TOKEN_ESCAPES), Ok(42));
    assert_eq!(verify(TOKEN_REORDERED_HEADER), Ok(42));
}

#[test]
fn sign_reproduces_the_python_token_byte_for_byte() {
    let mut out = Vec::new();
    jwt().sign(42, 1_700_000_000, EXP, &mut out);
    assert_eq!(out, TOKEN_LOADGEN.as_bytes());
}

#[test]
fn sign_appends_and_round_trips_extremes() {
    let mut out = b"prefix:".to_vec();
    jwt().sign(u64::MAX, u64::MAX, u64::MAX, &mut out);
    let token = &out[b"prefix:".len()..];
    assert_eq!(jwt().verify(token, 0), Ok(u64::MAX));
    assert_eq!(jwt().verify(token, u64::MAX), Err(JwtError::Expired));
}

#[test]
fn wrong_algorithms_are_rejected() {
    assert_eq!(verify(TOKEN_ALG_NONE), Err(JwtError::BadAlgorithm));
    assert_eq!(verify(TOKEN_HS512), Err(JwtError::BadAlgorithm));
    for header in [
        r#"{"alg":"HS384","typ":"JWT"}"#,
        r#"{"alg":"hs256"}"#,
        r#"{"alg":"HS256 "}"#,
        r#"{"alg":256}"#,
        r#"{"typ":"JWT"}"#,
        r#"{"alg":"HS256","alg":"HS256"}"#,
    ] {
        let token = mint(header, r#"{"sub":"1","iat":1,"exp":1702592000}"#);
        assert_eq!(verify(&token), Err(JwtError::BadAlgorithm), "{header}");
    }
    for header in ["[]", "\"HS256\"", "not json", "{"] {
        let token = mint(header, r#"{"sub":"1","iat":1,"exp":1702592000}"#);
        assert_eq!(verify(&token), Err(JwtError::Malformed), "{header}");
    }
}

#[test]
fn header_with_escape_in_alg_value_still_matches() {
    let token = mint(
        r#"{"alg":"HS256"}"#,
        r#"{"sub":"9","iat":1,"exp":1702592000}"#,
    );
    assert_eq!(verify(&token), Ok(9));
}

#[test]
fn tampering_is_detected() {
    let wrong_secret = Jwt::new(b"other-secret");
    assert_eq!(
        wrong_secret.verify(TOKEN_LOADGEN.as_bytes(), NOW),
        Err(JwtError::BadSignature)
    );

    // Swap in a payload for another user while keeping the original signature, and the reverse.
    let forged = mint_claims(r#"{"sub":"43","iat":1700000000,"exp":1702592000}"#);
    let (forged_signing_input, forged_signature) = forged.rsplit_once('.').unwrap();
    let (signing_input, signature) = TOKEN_LOADGEN.rsplit_once('.').unwrap();
    assert_eq!(
        verify(&format!("{forged_signing_input}.{signature}")),
        Err(JwtError::BadSignature)
    );
    assert_eq!(
        verify(&format!("{signing_input}.{forged_signature}")),
        Err(JwtError::BadSignature)
    );

    // Flip a character in the middle of the signature.
    let mut bytes = TOKEN_LOADGEN.as_bytes().to_vec();
    let at = bytes.len() - 20;
    bytes[at] = if bytes[at] == b'A' { b'B' } else { b'A' };
    assert_eq!(jwt().verify(&bytes, NOW), Err(JwtError::BadSignature));
}

#[test]
fn claims_errors() {
    assert_eq!(verify(TOKEN_NO_EXP), Err(JwtError::BadClaims));
    assert_eq!(verify(TOKEN_SUB_LETTERS), Err(JwtError::BadClaims));
    assert_eq!(verify(TOKEN_SUB_HUGE), Err(JwtError::BadClaims));
    assert_eq!(verify(TOKEN_EXP_FLOAT), Err(JwtError::BadClaims));
    assert_eq!(verify(TOKEN_SUB_NUMBER), Err(JwtError::BadClaims));
    for payload in [
        r#"{"sub":"","iat":1,"exp":1702592000}"#,
        r#"{"sub":"-5","iat":1,"exp":1702592000}"#,
        r#"{"sub":" 5","iat":1,"exp":1702592000}"#,
        r#"{"sub":"5","iat":1,"exp":-1}"#,
        r#"{"sub":"5","iat":1,"exp":"1702592000"}"#,
        r#"{"sub":"5","iat":1,"exp":null}"#,
        r#"{"sub":"5","iat":1,"exp":1702592000,"exp":1702592001}"#,
        r#"{"sub":"5","sub":"6","iat":1,"exp":1702592000}"#,
        r#"{"iat":1,"exp":1702592000}"#,
        r#"{}"#,
    ] {
        assert_eq!(
            verify(&mint_claims(payload)),
            Err(JwtError::BadClaims),
            "{payload}"
        );
    }
    for payload in [
        r#"{"sub":"5","iat":1,"exp":01702592000}"#,
        r#"{"sub":"5","iat":1,"exp":1702592000,}"#,
        r#"{"sub":"5","iat":{},"exp":1702592000}"#,
        r#"[1]"#,
        "null",
        "garbage",
    ] {
        assert_eq!(
            verify(&mint_claims(payload)),
            Err(JwtError::Malformed),
            "{payload}"
        );
    }
}

#[test]
fn lenient_where_the_rules_say_to_ignore() {
    // iat can be anything valid, nbf is ignored, leading zeros in a string sub are digits.
    let ok = r#"{"sub":"007","iat":"yesterday","nbf":9999999999,"exp":1702592000,"x":null}"#;
    assert_eq!(verify(&mint_claims(ok)), Ok(7));
    let loadgen_zeros = r#"{"sub":"007","iat":1,"exp":1702592000}"#;
    assert_eq!(verify(&mint_claims(loadgen_zeros)), Ok(7));
    let max = r#"{"sub":"18446744073709551615","iat":1,"exp":1702592000}"#;
    assert_eq!(verify(&mint_claims(max)), Ok(u64::MAX));
}

#[test]
fn expiry_boundary() {
    let token = TOKEN_LOADGEN.as_bytes();
    assert_eq!(jwt().verify(token, EXP - 1), Ok(42));
    assert_eq!(jwt().verify(token, EXP), Err(JwtError::Expired));
    assert_eq!(jwt().verify(token, EXP + 1), Err(JwtError::Expired));
    assert_eq!(
        jwt().verify(TOKEN_ALPHABETICAL.as_bytes(), EXP),
        Err(JwtError::Expired)
    );
    let zero = mint_claims(r#"{"sub":"1","iat":0,"exp":0}"#);
    assert_eq!(jwt().verify(zero.as_bytes(), 0), Err(JwtError::Expired));
}

#[test]
fn structure_errors() {
    let extra = format!("{TOKEN_LOADGEN}.abc");
    let two_segments = TOKEN_LOADGEN.rsplit_once('.').unwrap().0;
    let (header, rest) = TOKEN_LOADGEN.split_once('.').unwrap();
    let (payload, signature) = rest.split_once('.').unwrap();
    for token in [
        "",
        ".",
        "..",
        "a.b",
        "a.b.c.d",
        extra.as_str(),
        two_segments,
        &format!(".{payload}.{signature}"),
        &format!("{header}..{signature}"),
        &format!("{header}.{payload}."),
        &format!("{header}.{payload}.{}", &signature[..42]),
        &format!("{header}.{payload}.{signature}A"),
    ] {
        assert_eq!(verify(token), Err(JwtError::Malformed), "{token}");
    }
}

#[test]
fn rejects_standard_base64_and_padding() {
    // Python's signature has '_' and '-'; the standard alphabet spells them '/' and '+'.
    assert_eq!(
        verify(&TOKEN_LOADGEN.replace("__", "//")),
        Err(JwtError::Malformed)
    );
    assert_eq!(
        verify(&TOKEN_LOADGEN.replace('-', "+")),
        Err(JwtError::Malformed)
    );
    let (head, signature) = TOKEN_LOADGEN.rsplit_once('.').unwrap();
    assert_eq!(
        verify(&format!("{head}.{signature}=")),
        Err(JwtError::Malformed)
    );
    // Padding inside the signed text changes what was signed, so the signature check fires first.
    let padded_payload = TOKEN_LOADGEN.replacen("fQ.", "fQ==.", 1);
    assert_eq!(verify(&padded_payload), Err(JwtError::BadSignature));
    // Correctly signed, but the payload segment carries padding: the payload decode refuses it.
    let mut text = Vec::new();
    text.extend_from_slice(HEADER_B64);
    text.extend_from_slice(b".e30=");
    let signature = HmacSha256::new(SECRET).mac(&[&text]);
    text.push(b'.');
    base64::encode_url(&signature, &mut text);
    assert_eq!(jwt().verify(&text, NOW), Err(JwtError::Malformed));
}

#[test]
fn very_long_tokens_are_rejected_up_front() {
    let big_claim = "x".repeat(900);
    let long = mint_claims(&format!(
        r#"{{"sub":"1","iat":1,"exp":1702592000,"pad":"{big_claim}"}}"#
    ));
    assert!(long.len() > MAX_TOKEN_LEN);
    assert_eq!(verify(&long), Err(JwtError::Malformed));
    let at_limit = vec![b'a'; MAX_TOKEN_LEN];
    assert_eq!(jwt().verify(&at_limit, NOW), Err(JwtError::Malformed));
    let over = vec![b'a'; MAX_TOKEN_LEN + 1];
    assert_eq!(jwt().verify(&over, NOW), Err(JwtError::Malformed));
}

#[test]
fn a_token_just_under_the_limit_still_verifies() {
    let mut pad = 600;
    loop {
        let token = mint_claims(&format!(
            r#"{{"sub":"1","iat":1,"exp":1702592000,"p":"{}"}}"#,
            "x".repeat(pad)
        ));
        if token.len() <= MAX_TOKEN_LEN {
            assert_eq!(verify(&token), Ok(1));
            if token.len() > MAX_TOKEN_LEN - 4 {
                return;
            }
        }
        pad += 1;
        assert!(pad < 1000);
    }
}

#[test]
fn fast_and_general_paths_agree() {
    for payload in [
        r#"{"sub":"42","iat":1700000000,"exp":1702592000}"#,
        r#"{"sub":"0","iat":0,"exp":0}"#,
        r#"{"sub":"18446744073709551615","iat":99999999999999999999999,"exp":18446744073709551615}"#,
    ] {
        let exact =
            claims_exact_layout(payload.as_bytes()).expect("fast path matches its own layout");
        assert_eq!(claims_general(payload.as_bytes()), Ok(exact), "{payload}");
    }
    // Layout look-alikes the fast path must decline (the general path then decides).
    for payload in [
        r#"{"sub":"42","iat":1,"exp":01}"#,
        r#"{"sub":"42","iat":01,"exp":1}"#,
        r#"{"sub":"42","iat":,"exp":1}"#,
        r#"{"sub":"","iat":1,"exp":1}"#,
        r#"{"sub":"42","iat":1,"exp":1} "#,
        r#"{"sub":"42","iat":1,"exp":99999999999999999999}"#,
        r#"{"sub":"42","iat":1,"exp":1.5}"#,
    ] {
        assert_eq!(claims_exact_layout(payload.as_bytes()), None, "{payload}");
    }
}

#[test]
fn payload_buffer_is_big_enough_for_the_longest_claims() {
    let mut out = Vec::new();
    let mut buf = [0u8; PAYLOAD_MAX_LEN];
    let len = write_payload(u64::MAX, u64::MAX, u64::MAX, &mut buf);
    assert_eq!(len, 84);
    jwt().sign(u64::MAX, u64::MAX, u64::MAX, &mut out);
    assert!(out.len() < MAX_TOKEN_LEN);
}

#[test]
fn error_display_is_not_empty() {
    for e in [
        JwtError::Malformed,
        JwtError::BadAlgorithm,
        JwtError::BadSignature,
        JwtError::Expired,
        JwtError::BadClaims,
    ] {
        assert!(!e.to_string().is_empty());
    }
}

/// Run with `cargo test --release -- --ignored --nocapture`.
#[test]
#[ignore]
fn bench_verify() {
    let jwt = jwt();
    let loadgen = TOKEN_LOADGEN.as_bytes();
    let alphabetical = TOKEN_ALPHABETICAL.as_bytes();
    for (name, token) in [
        ("fast path (loadgen layout)", loadgen),
        ("general path (alphabetical keys)", alphabetical),
    ] {
        const ITERATIONS: u32 = 1_000_000;
        let mut sum = 0u64;
        let start = std::time::Instant::now();
        for i in 0..ITERATIONS {
            sum = sum.wrapping_add(
                jwt.verify(std::hint::black_box(token), NOW + u64::from(i & 1))
                    .unwrap_or(0),
            );
        }
        let ns = start.elapsed().as_nanos() as f64 / f64::from(ITERATIONS);
        println!("jwt verify, {name}: {ns:.1} ns (sum {sum})");
    }
}
