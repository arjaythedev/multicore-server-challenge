#[test]
fn jwt_validation() {
    use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD as B64};
    use hmac::{Hmac, Mac};
    use sha2::Sha256;
    let key = "test-key";
    let jwt = crate::auth::Jwt::new(key);
    let make = |header: &str, claims: &str| {
        let mut token = format!("{}.{}", B64.encode(header), B64.encode(claims));
        let mut mac = Hmac::<Sha256>::new_from_slice(key.as_bytes()).unwrap();
        mac.update(token.as_bytes());
        token.push('.');
        B64.encode_string(mac.finalize().into_bytes(), &mut token);
        token
    };
    assert_eq!(jwt.verify(&jwt.issue(123)), Some(123));
    assert_eq!(
        crate::auth::Jwt::new("other-key").verify(&jwt.issue(123)),
        None
    );
    assert_eq!(
        jwt.verify(&make(r#"{"alg":"HS256"}"#, r#"{"sub":"123","exp":1}"#)),
        None
    );
    assert_eq!(
        jwt.verify(&make(
            r#"{"alg":"none"}"#,
            r#"{"sub":"123","exp":9999999999}"#
        )),
        None
    );
    assert_eq!(
        jwt.verify(&make(
            r#"{"alg":"HS256"}"#,
            r#"{"sub":"123","exp":9999999999,"nbf":9999999998}"#
        )),
        None
    );
    assert_eq!(
        jwt.verify(&make(
            r#"{"alg":"HS256"}"#,
            r#"{"sub":"\u0031\u0032\u0033","exp":9999999999}"#
        )),
        Some(123)
    );
    let long = format!(
        r#"{{"sub":"123","exp":9999999999,"extra":"{}"}}"#,
        "x".repeat(4096)
    );
    assert_eq!(jwt.verify(&make(r#"{"alg":"HS256"}"#, &long)), Some(123));
    assert_eq!(
        jwt.verify(&make(
            r#"{"alg":"HS256"}"#,
            r#"{"sub":"0","exp":9999999999}"#
        )),
        None
    );
    assert_eq!(jwt.verify(&format!("{}x", jwt.issue(123))), None);
    // Payloads near the issued shape: the direct reader must agree with serde_json on each.
    let hs = r#"{"alg":"HS256","typ":"JWT"}"#;
    for (claims, id) in [
        (r#"{"sub":"123","iat":1,"exp":9999999999}"#, Some(123)),
        (r#"{"sub":"0123","iat":1,"exp":9999999999}"#, Some(123)),
        (r#"{"sub":"123","iat":01,"exp":9999999999}"#, None),
        (r#"{"sub":"123","iat":1,"exp":09999999999}"#, None),
        (r#"{"sub":"123","iat":1,"exp":1}"#, None),
        (r#"{"sub":"123","iat":1,"exp":0}"#, None),
        (r#"{"sub":"123","iat":1,"exp":9999999999.5}"#, Some(123)),
        (r#"{"sub":"123","iat":1,"exp":9999999999e0}"#, Some(123)),
        (
            r#"{"sub":"123","iat":1,"exp":99999999999999999999}"#,
            Some(123),
        ),
        (
            r#"{"sub":"123","iat":1,"exp":9999999999,"nbf":9999999998}"#,
            None,
        ),
        (r#"{"sub":"123","iat":1,"exp":9999999999} "#, Some(123)),
        (r#"{"sub":"123","iat":1,"exp":9999999999}x"#, None),
        (r#"{"sub":"123","iat":1,"exp":9999999999,"sub":"5"}"#, None),
        (r#"{"sub":"","iat":1,"exp":9999999999}"#, None),
        (r#"{"sub":"12a","iat":1,"exp":9999999999}"#, None),
        (r#"{"sub":"123","iat":-1,"exp":9999999999}"#, Some(123)),
    ] {
        let token = make(hs, claims);
        assert!(token.starts_with("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9."));
        assert_eq!(jwt.verify(&token), id, "{claims}");
    }
    for (header, claims) in [
        (r#"["HS256"]"#, r#"{"sub":"123","exp":9999999999}"#),
        (r#"{"alg":"HS256"}"#, r#"["123",9999999999,null]"#),
    ] {
        assert_eq!(jwt.verify(&make(header, claims)), None);
    }
}
