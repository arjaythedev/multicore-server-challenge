//! PostgreSQL v3 wire-protocol message types, SCRAM-SHA-256, and binary array codecs.

use base64::engine::general_purpose::STANDARD as B64_STANDARD;
use base64::Engine;
use hmac::{Hmac, Mac};
use sha2::{Digest, Sha256};

type HmacSha256 = Hmac<Sha256>;

pub const INT8_OID: i32 = 20;
pub const INT4_OID: i32 = 23;
pub const TEXT_OID: i32 = 25;

/// Encodes an i64 slice into PostgreSQL binary INT8 array format.
pub fn encode_i64_array(values: &[i64], dst: &mut Vec<u8>) {
    dst.extend_from_slice(&(1i32).to_be_bytes()); // ndim = 1
    dst.extend_from_slice(&(0i32).to_be_bytes()); // has_null = 0
    dst.extend_from_slice(&INT8_OID.to_be_bytes()); // element_oid
    dst.extend_from_slice(&(values.len() as i32).to_be_bytes()); // dim length
    dst.extend_from_slice(&(1i32).to_be_bytes()); // lower bound = 1

    for &val in values {
        dst.extend_from_slice(&(8i32).to_be_bytes()); // len = 8
        dst.extend_from_slice(&val.to_be_bytes());
    }
}

/// Encodes a string slice into PostgreSQL binary TEXT array format.
pub fn encode_text_array<T: AsRef<str>>(values: &[T], dst: &mut Vec<u8>) {
    dst.extend_from_slice(&(1i32).to_be_bytes()); // ndim = 1
    dst.extend_from_slice(&(0i32).to_be_bytes()); // has_null = 0
    dst.extend_from_slice(&TEXT_OID.to_be_bytes()); // element_oid
    dst.extend_from_slice(&(values.len() as i32).to_be_bytes()); // dim length
    dst.extend_from_slice(&(1i32).to_be_bytes()); // lower bound = 1

    for val in values {
        let bytes = val.as_ref().as_bytes();
        dst.extend_from_slice(&(bytes.len() as i32).to_be_bytes());
        dst.extend_from_slice(bytes);
    }
}

/// Parses a PostgreSQL binary text array into a vector of strings.
pub fn decode_text_array(mut data: &[u8]) -> Vec<String> {
    if data.len() < 20 {
        return Vec::new();
    }
    let ndim = i32::from_be_bytes(data[0..4].try_into().unwrap());
    if ndim == 0 {
        return Vec::new();
    }
    let elem_count = i32::from_be_bytes(data[12..16].try_into().unwrap()) as usize;
    data = &data[20..];

    let mut out = Vec::with_capacity(elem_count);
    for _ in 0..elem_count {
        if data.len() < 4 {
            break;
        }
        let len = i32::from_be_bytes(data[0..4].try_into().unwrap());
        data = &data[4..];
        if len >= 0 {
            let ulen = len as usize;
            if data.len() >= ulen {
                if let Ok(s) = std::str::from_utf8(&data[..ulen]) {
                    out.push(s.to_string());
                }
                data = &data[ulen..];
            }
        }
    }
    out
}

/// Computes PBKDF2 with HMAC-SHA-256 for SCRAM auth.
fn pbkdf2_sha256(password: &[u8], salt: &[u8], iterations: u32) -> [u8; 32] {
    let mut mac = HmacSha256::new_from_slice(password).expect("HMAC new");
    mac.update(salt);
    mac.update(&(1u32).to_be_bytes());
    let mut u = mac.finalize().into_bytes();
    let mut result = [0u8; 32];
    result.copy_from_slice(&u);

    for _ in 1..iterations {
        let mut mac = HmacSha256::new_from_slice(password).expect("HMAC new");
        mac.update(&u);
        u = mac.finalize().into_bytes();
        for (r, b) in result.iter_mut().zip(u.iter()) {
            *r ^= b;
        }
    }

    result
}

/// SCRAM-SHA-256 client authentication state machine.
pub struct ScramClient {
    username: String,
    password: Vec<u8>,
    client_nonce: String,
    client_first_bare: String,
    server_signature: [u8; 32],
}

impl ScramClient {
    pub fn new(username: &str, password: &str) -> Self {
        let mut random_bytes = [0u8; 18];
        getrandom::fill(&mut random_bytes).expect("RNG");
        let client_nonce = B64_STANDARD.encode(random_bytes);
        let client_first_bare = format!("n={},r={}", username, client_nonce);

        ScramClient {
            username: username.to_string(),
            password: password.as_bytes().to_vec(),
            client_nonce,
            client_first_bare,
            server_signature: [0u8; 32],
        }
    }

    pub fn client_first_message(&self) -> String {
        format!("n,,{}", self.client_first_bare)
    }

    pub fn process_server_first(&mut self, server_msg: &str) -> Result<String, ()> {
        let mut server_nonce = None;
        let mut salt_b64 = None;
        let mut iter_count = None;

        for part in server_msg.split(',') {
            if let Some(r) = part.strip_prefix("r=") {
                server_nonce = Some(r);
            } else if let Some(s) = part.strip_prefix("s=") {
                salt_b64 = Some(s);
            } else if let Some(i) = part.strip_prefix("i=") {
                iter_count = i.parse::<u32>().ok();
            }
        }

        let s_nonce = server_nonce.ok_or(())?;
        if !s_nonce.starts_with(&self.client_nonce) {
            return Err(());
        }
        let salt = B64_STANDARD.decode(salt_b64.ok_or(())?).map_err(|_| ())?;
        let iterations = iter_count.ok_or(())?;

        let salted_password = pbkdf2_sha256(&self.password, &salt, iterations);

        // ClientKey = HMAC(SaltedPassword, "Client Key")
        let mut mac = HmacSha256::new_from_slice(&salted_password).map_err(|_| ())?;
        mac.update(b"Client Key");
        let client_key = mac.finalize().into_bytes();

        // StoredKey = SHA256(ClientKey)
        let stored_key = Sha256::digest(client_key);

        let client_final_without_proof = format!("c=biws,r={}", s_nonce);
        let auth_message = format!("{},{},{}", self.client_first_bare, server_msg, client_final_without_proof);

        // ClientSignature = HMAC(StoredKey, AuthMessage)
        let mut mac = HmacSha256::new_from_slice(&stored_key).map_err(|_| ())?;
        mac.update(auth_message.as_bytes());
        let client_signature = mac.finalize().into_bytes();

        // ClientProof = ClientKey XOR ClientSignature
        let mut client_proof = [0u8; 32];
        for i in 0..32 {
            client_proof[i] = client_key[i] ^ client_signature[i];
        }

        // ServerKey = HMAC(SaltedPassword, "Server Key")
        let mut mac = HmacSha256::new_from_slice(&salted_password).map_err(|_| ())?;
        mac.update(b"Server Key");
        let server_key = mac.finalize().into_bytes();

        // ServerSignature = HMAC(ServerKey, AuthMessage)
        let mut mac = HmacSha256::new_from_slice(&server_key).map_err(|_| ())?;
        mac.update(auth_message.as_bytes());
        self.server_signature.copy_from_slice(&mac.finalize().into_bytes());

        let proof_b64 = B64_STANDARD.encode(client_proof);
        Ok(format!("{},p={}", client_final_without_proof, proof_b64))
    }

    pub fn verify_server_final(&self, server_msg: &str) -> Result<(), ()> {
        let v = server_msg.strip_prefix("v=").ok_or(())?;
        let expected_b64 = B64_STANDARD.encode(self.server_signature);
        if v == expected_b64 {
            Ok(())
        } else {
            Err(())
        }
    }
}
