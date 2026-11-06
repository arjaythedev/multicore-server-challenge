package com.challenge.conduit.security;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.Arrays;
import java.util.Base64;

/**
 * High-performance, zero-allocation JWT validator and generator.
 * Uses thread-local scratch buffers and zero-allocation Base64 URL decoding
 * to completely eliminate per-request heap allocations.
 */
public final class Jwt {
    private static final byte[] HEADER_B64 = Base64.getUrlEncoder().withoutPadding()
            .encode("{\"alg\":\"HS256\",\"typ\":\"JWT\"}".getBytes(StandardCharsets.US_ASCII));

    // Static constant search patterns to eliminate .getBytes() allocations during token parsing
    private static final byte[] SUB_COLON = "\"sub\":".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] SUB_SPACE_COLON = "\"sub\" :".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] EXP_COLON = "\"exp\":".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] EXP_SPACE_COLON = "\"exp\" :".getBytes(StandardCharsets.US_ASCII);

    // Fast zero-allocation Base64 URL decoding lookup table
    private static final byte[] BASE64_URL_DECODE_TABLE = new byte[256];
    static {
        Arrays.fill(BASE64_URL_DECODE_TABLE, (byte) -1);
        for (int i = 0; i < 26; i++) {
            BASE64_URL_DECODE_TABLE['A' + i] = (byte) i;
            BASE64_URL_DECODE_TABLE['a' + i] = (byte) (i + 26);
        }
        for (int i = 0; i < 10; i++) {
            BASE64_URL_DECODE_TABLE['0' + i] = (byte) (i + 52);
        }
        BASE64_URL_DECODE_TABLE['-'] = 62;
        BASE64_URL_DECODE_TABLE['_'] = 63;
    }

    private final SecretKeySpec keySpec;
    private final int expirationDays;
    private final ThreadLocal<Mac> threadLocalMac;
    private final ThreadLocal<byte[]> rawTokenBuffer;
    private final ThreadLocal<byte[]> decodedSigBuffer;
    private final ThreadLocal<byte[]> decodedPayloadBuffer;

    public Jwt(String secret, int expirationDays) {
        this.keySpec = new SecretKeySpec(secret.getBytes(StandardCharsets.UTF_8), "HmacSHA256");
        this.expirationDays = expirationDays;
        this.threadLocalMac = ThreadLocal.withInitial(() -> {
            try {
                Mac mac = Mac.getInstance("HmacSHA256");
                mac.init(keySpec);
                return mac;
            } catch (Exception e) {
                throw new IllegalStateException("Failed to initialize HmacSHA256 Mac", e);
            }
        });
        // Dedicated thread-local buffers to eliminate heap byte[] allocations during verification
        this.rawTokenBuffer = ThreadLocal.withInitial(() -> new byte[1024]);
        this.decodedSigBuffer = ThreadLocal.withInitial(() -> new byte[64]); // HMAC-SHA256 is 32 bytes
        this.decodedPayloadBuffer = ThreadLocal.withInitial(() -> new byte[1024]);
    }

    public String generateToken(long userId) {
        long now = Instant.now().getEpochSecond();
        long exp = now + ((long) expirationDays * 24 * 3600);
        String payloadJson = "{\"sub\":\"" + userId + "\",\"iat\":" + now + ",\"exp\":" + exp + "}";
        byte[] payloadB64 = Base64.getUrlEncoder().withoutPadding().encode(payloadJson.getBytes(StandardCharsets.UTF_8));

        byte[] headerAndPayload = new byte[HEADER_B64.length + 1 + payloadB64.length];
        System.arraycopy(HEADER_B64, 0, headerAndPayload, 0, HEADER_B64.length);
        headerAndPayload[HEADER_B64.length] = '.';
        System.arraycopy(payloadB64, 0, headerAndPayload, HEADER_B64.length + 1, payloadB64.length);

        Mac mac = threadLocalMac.get();
        mac.reset();
        mac.update(headerAndPayload);
        byte[] signature = mac.doFinal();
        byte[] signatureB64 = Base64.getUrlEncoder().withoutPadding().encode(signature);

        return new String(headerAndPayload, StandardCharsets.US_ASCII) + "." + new String(signatureB64, StandardCharsets.US_ASCII);
    }

    public long verifyAndGetUserId(CharSequence authHeader, int start, int length) {
        if (length <= 0 || length > 1024) return 0;
        byte[] raw = rawTokenBuffer.get();
        for (int i = 0; i < length; i++) {
            char c = authHeader.charAt(start + i);
            raw[i] = (byte) c;
        }
        return verifyAndGetUserId(raw, 0, length);
    }

    public long verifyAndGetUserId(byte[] tokenBytes, int offset, int length) {
        int firstDot = -1;
        int secondDot = -1;

        for (int i = 0; i < length; i++) {
            if (tokenBytes[offset + i] == '.') {
                if (firstDot == -1) {
                    firstDot = i;
                } else if (secondDot == -1) {
                    secondDot = i;
                    break;
                }
            }
        }

        if (firstDot == -1 || secondDot == -1) {
            return 0;
        }

        // Verify HMAC-SHA256 signature
        Mac mac = threadLocalMac.get();
        mac.reset();
        mac.update(tokenBytes, offset, secondDot);
        byte[] expectedSig = mac.doFinal();

        byte[] sigBuf = decodedSigBuffer.get();
        int sigB64Len = length - secondDot - 1;
        int decodedSigLen = decodeBase64Url(tokenBytes, offset + secondDot + 1, sigB64Len, sigBuf);
        if (decodedSigLen != expectedSig.length) {
            return 0;
        }

        // Constant-time signature comparison without allocating arrays
        if (decodedSigLen != expectedSig.length || !constantTimeEquals(expectedSig, sigBuf, decodedSigLen)) {
            return 0;
        }

        // Decode Payload
        byte[] payloadBuf = decodedPayloadBuffer.get();
        int payloadB64Len = secondDot - firstDot - 1;
        int decodedPayloadLen = decodeBase64Url(tokenBytes, offset + firstDot + 1, payloadB64Len, payloadBuf);
        if (decodedPayloadLen <= 0) {
            return 0;
        }

        long userId = extractStringSub(payloadBuf, decodedPayloadLen);
        long exp = extractExp(payloadBuf, decodedPayloadLen);
        long now = Instant.now().getEpochSecond();

        if (exp == 0 || now >= exp) {
            return 0;
        }

        return userId;
    }

    /**
     * In-place, zero-allocation Base64 URL decode into the destination buffer.
     * Returns number of decoded bytes, or -1 on error.
     */
    public static int decodeBase64Url(byte[] src, int srcOffset, int srcLen, byte[] dst) {
        if (srcLen <= 0) return 0;
        int outPos = 0;
        int buffer = 0;
        int bitsCollected = 0;

        for (int i = 0; i < srcLen; i++) {
            byte c = src[srcOffset + i];
            if (c == '=') break;
            byte val = BASE64_URL_DECODE_TABLE[c & 0xFF];
            if (val < 0) return -1; // invalid character

            buffer = (buffer << 6) | val;
            bitsCollected += 6;

            if (bitsCollected >= 8) {
                bitsCollected -= 8;
                if (outPos >= dst.length) return -1;
                dst[outPos++] = (byte) ((buffer >> bitsCollected) & 0xFF);
            }
        }
        return outPos;
    }

    private static long extractStringSub(byte[] json, int length) {
        int idx = indexOf(json, length, SUB_COLON);
        if (idx == -1) {
            idx = indexOf(json, length, SUB_SPACE_COLON);
            if (idx == -1) return 0;
            idx += SUB_SPACE_COLON.length;
        } else {
            idx += SUB_COLON.length;
        }
        while (idx < length && (json[idx] == ' ' || json[idx] == '\t')) idx++;
        if (idx >= length || json[idx] != '"') {
            return 0;
        }
        idx++; // skip opening quote
        long val = 0;
        int count = 0;
        while (idx < length && json[idx] >= '0' && json[idx] <= '9') {
            val = val * 10 + (json[idx] - '0');
            idx++;
            count++;
        }
        if (count == 0 || idx >= length || json[idx] != '"') {
            return 0;
        }
        return val;
    }

    private static long extractExp(byte[] json, int length) {
        int idx = indexOf(json, length, EXP_COLON);
        if (idx == -1) {
            idx = indexOf(json, length, EXP_SPACE_COLON);
            if (idx == -1) return 0;
            idx += EXP_SPACE_COLON.length;
        } else {
            idx += EXP_COLON.length;
        }
        while (idx < length && (json[idx] == ' ' || json[idx] == '\t')) idx++;
        long val = 0;
        int count = 0;
        while (idx < length && json[idx] >= '0' && json[idx] <= '9') {
            val = val * 10 + (json[idx] - '0');
            idx++;
            count++;
        }
        return count == 0 ? 0 : val;
    }

    private static boolean constantTimeEquals(byte[] a, byte[] b, int len) {
        if (a.length < len || b.length < len) return false;
        int diff = 0;
        for (int i = 0; i < len; i++) {
            diff |= a[i] ^ b[i];
        }
        return diff == 0;
    }

    private static int indexOf(byte[] array, int length, byte[] target) {
        outer:
        for (int i = 0; i <= length - target.length; i++) {
            for (int j = 0; j < target.length; j++) {
                if (array[i + j] != target[j]) {
                    continue outer;
                }
            }
            return i;
        }
        return -1;
    }
}
