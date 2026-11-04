#[cfg(all(feature = "batch-bcrypt", target_os = "linux"))]
#[path = "password_batch.rs"]
mod batch;
#[cfg(all(feature = "batch-bcrypt", target_os = "linux"))]
pub use batch::Pool;

// Portable bcrypt, with an optional Openwall backend for matched experiments.
// Both paths perform full cost-10 work. Embedded NULs use the byte-oriented Rust
// implementation because the native core accepts C strings.
pub fn hash(password: &str) -> Result<String, String> {
    #[cfg(all(feature = "native-bcrypt", target_os = "linux"))]
    if !password.as_bytes().contains(&0) {
        return native::hash(password);
    }
    bcrypt::hash(password, crate::BCRYPT_COST).map_err(|e| e.to_string())
}
pub fn verify(password: &str, hash: &str) -> bool {
    #[cfg(all(feature = "native-bcrypt", target_os = "linux"))]
    if !password.as_bytes().contains(&0) {
        return native::verify(password, hash);
    }
    bcrypt::verify(password, hash).unwrap_or(false)
}
#[cfg(all(feature = "native-bcrypt", target_os = "linux"))]
mod native {
    use base64::Engine;
    use std::ffi::{CStr, c_char, c_void};
    use subtle::ConstantTimeEq;
    unsafe extern "C" {
        fn crypt_bcrypt_rn(
            phrase: *const c_char,
            phrase_size: usize,
            setting: *const c_char,
            setting_size: usize,
            output: *mut u8,
            output_size: usize,
            scratch: *mut c_void,
            scratch_size: usize,
        );
    }
    fn run(password: &str, setting: &CStr) -> Option<[u8; 60]> {
        if password.len() > 72 || password.as_bytes().contains(&0) {
            return None;
        }
        let mut phrase = [0u8; 73];
        phrase[..password.len()].copy_from_slice(password.as_bytes());
        let mut state = [0usize; 8192 / std::mem::size_of::<usize>()];
        let mut result = [0u8; 61];
        // SAFETY: terminated inputs are live for the call. Both output buffers are
        // exclusively owned, correctly aligned, and their exact lengths are passed.
        // The C core statically asserts that 8192 bytes hold its working state.
        unsafe {
            crypt_bcrypt_rn(
                phrase.as_ptr().cast(),
                password.len(),
                setting.as_ptr(),
                setting.to_bytes().len(),
                result.as_mut_ptr(),
                result.len(),
                state.as_mut_ptr().cast(),
                8192,
            );
        }
        if result[0] != b'$' || result[60] != 0 {
            return None;
        }
        result[..60].try_into().ok()
    }
    pub(super) fn salt() -> Result<[u8; 30], String> {
        let mut random = [0u8; 16];
        getrandom::fill(&mut random).map_err(|e| e.to_string())?;
        let mut salt = [0u8; 30];
        salt[..7].copy_from_slice(b"$2b$10$");
        base64::engine::GeneralPurpose::new(
            &base64::alphabet::BCRYPT,
            base64::engine::general_purpose::NO_PAD,
        )
        .encode_slice(random, &mut salt[7..29])
        .map_err(|e| e.to_string())?;
        Ok(salt)
    }
    #[cfg(feature = "batch-bcrypt")]
    pub(super) fn compute_batch(inputs: &[(&str, &CStr)]) -> Option<Vec<[u8; 60]>> {
        if inputs.len() == 1 {
            return run(inputs[0].0, inputs[0].1).map(|h| vec![h]);
        }
        if !(2..=4).contains(&inputs.len()) {
            return None;
        }
        unsafe extern "C" {
            fn conduit_bcrypt_batch(
                keys: *const *const c_char,
                settings: *const *const c_char,
                output: *mut [u8; 61],
                count: u32,
            ) -> i32;
        }
        let mut keys = [[0u8; 73]; 4];
        let mut key_ptrs = [std::ptr::null(); 4];
        let mut setting_ptrs = [std::ptr::null(); 4];
        let mut output = [[0u8; 61]; 4];
        for (i, (password, setting)) in inputs.iter().enumerate() {
            if password.len() > 72 || password.as_bytes().contains(&0) {
                return None;
            }
            keys[i][..password.len()].copy_from_slice(password.as_bytes());
            key_ptrs[i] = keys[i].as_ptr().cast();
            setting_ptrs[i] = setting.as_ptr();
        }
        // SAFETY: 2..=4 independent NUL-terminated inputs and disjoint 61-byte
        // outputs remain live for the call. The C dispatcher selects that fixed
        // lane count, validates settings, and indexes each table in 0..256.
        let ok = unsafe {
            conduit_bcrypt_batch(
                key_ptrs.as_ptr(),
                setting_ptrs.as_ptr(),
                output.as_mut_ptr(),
                inputs.len() as u32,
            )
        };
        if ok == 0 {
            return None;
        }
        output[..inputs.len()]
            .iter()
            .map(|o| {
                if o[0] != b'$' || o[60] != 0 {
                    None
                } else {
                    o[..60].try_into().ok()
                }
            })
            .collect()
    }
    #[cfg(feature = "batch-bcrypt")]
    pub(super) fn batch_self_test() {
        let inputs = [
            ("batch self test", c"$2a$04$abcdefghijklmnopqrstuu"),
            ("één 🙂", c"$2b$04$......................"),
            ("", c"$2y$04$abcdefghijklmnopqrstuu"),
            (
                "123456789012345678901234567890123456789012345678901234567890123456789012",
                c"$2b$04$012345678901234567890u",
            ),
        ];
        let serial: Vec<_> = inputs
            .iter()
            .map(|(p, s)| run(p, s).expect("bcrypt self-test"))
            .collect();
        for n in 2..=4 {
            assert_eq!(
                compute_batch(&inputs[..n]).expect("batch bcrypt self-test"),
                serial[..n],
                "batch bcrypt self-test"
            );
        }
    }
    pub(super) fn hash(password: &str) -> Result<String, String> {
        let salt = salt()?;
        let salt = CStr::from_bytes_with_nul(&salt).map_err(|e| e.to_string())?;
        let hash = run(password, salt).ok_or("bcrypt failed")?;
        String::from_utf8(hash.to_vec()).map_err(|e| e.to_string())
    }
    pub(super) fn valid_setting(hash: &str) -> bool {
        hash.len() == 60
            && ["$2a$10$", "$2b$10$", "$2y$10$"]
                .iter()
                .any(|p| hash.starts_with(p))
    }
    pub(super) fn verify(password: &str, hash: &str) -> bool {
        if !valid_setting(hash) {
            return false;
        }
        let mut salt = [0u8; 61];
        salt[..60].copy_from_slice(hash.as_bytes());
        let Ok(salt) = CStr::from_bytes_with_nul(&salt) else {
            return false;
        };
        run(password, salt)
            .is_some_and(|result| bool::from(result.as_slice().ct_eq(hash.as_bytes())))
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn bcrypt_interoperates() {
        for password in [
            "password123",
            "één 🙂",
            "",
            "abc\0def",
            "123456789012345678901234567890123456789012345678901234567890123456789012",
        ] {
            let hash = super::hash(password).unwrap();
            assert!(bcrypt::verify(password, &hash).unwrap());
            assert!(super::verify(password, &hash));
            assert!(!super::verify("incorrect", &hash));
            let portable = bcrypt::hash(password, 10).unwrap();
            assert!(super::verify(password, &portable));
        }
    }
}

#[cfg(all(test, feature = "native-bcrypt", target_os = "linux"))]
#[test]
#[ignore]
fn compare_bcrypt_backends() {
    let h = bcrypt::hash("password123", 10).unwrap();
    for _ in 0..2 {
        let t = std::time::Instant::now();
        for _ in 0..30 {
            assert!(bcrypt::verify("password123", &h).unwrap());
        }
        eprintln!(
            "portable verify: {:.3} ms",
            t.elapsed().as_secs_f64() * 1000.0 / 30.0
        );
        let t = std::time::Instant::now();
        for _ in 0..30 {
            assert!(verify("password123", &h));
        }
        eprintln!(
            "native verify: {:.3} ms",
            t.elapsed().as_secs_f64() * 1000.0 / 30.0
        );
    }
}
