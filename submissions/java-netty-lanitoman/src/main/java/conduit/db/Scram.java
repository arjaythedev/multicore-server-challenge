package conduit.db;

import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Base64;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/**
 * The client side of SCRAM-SHA-256 (RFC 5802 / RFC 7677), the password authentication Postgres uses by default:
 * client-first, server-first, client-final (with the proof), server-final (with the server's signature).
 */
final class Scram {
    private final String password;
    private final String clientNonce;
    private final String clientFirstBare;
    private byte[] expectedServerSignature;

    Scram(String password) {
        this.password = password;
        byte[] nonce = new byte[18];
        new SecureRandom().nextBytes(nonce);
        this.clientNonce = Base64.getEncoder().encodeToString(nonce);
        // Postgres takes the user name from the startup message, so the SCRAM user name is left as "*".
        this.clientFirstBare = "n=*,r=" + clientNonce;
    }

    /** The SASLInitialResponse body: mechanism name, then the length-prefixed client-first message. */
    byte[] clientFirstMessage() {
        byte[] mechanism = "SCRAM-SHA-256\0".getBytes(StandardCharsets.US_ASCII);
        byte[] first = ("n,," + clientFirstBare).getBytes(StandardCharsets.US_ASCII);
        byte[] body = new byte[mechanism.length + 4 + first.length];
        System.arraycopy(mechanism, 0, body, 0, mechanism.length);
        int at = mechanism.length;
        body[at] = (byte) (first.length >>> 24);
        body[at + 1] = (byte) (first.length >>> 16);
        body[at + 2] = (byte) (first.length >>> 8);
        body[at + 3] = (byte) first.length;
        System.arraycopy(first, 0, body, at + 4, first.length);
        return body;
    }

    /** Answers the server-first message "r=nonce,s=salt,i=iterations" with the client-final message. */
    byte[] clientFinalMessage(String serverFirst) throws GeneralSecurityException {
        String nonce = null;
        String salt = null;
        int iterations = 0;
        for (String part : serverFirst.split(",")) {
            if (part.startsWith("r=")) nonce = part.substring(2);
            else if (part.startsWith("s=")) salt = part.substring(2);
            else if (part.startsWith("i=")) iterations = Integer.parseInt(part.substring(2));
        }
        if (nonce == null || !nonce.startsWith(clientNonce) || salt == null || iterations <= 0) {
            throw new GeneralSecurityException("bad SCRAM server-first message");
        }
        String clientFinalWithoutProof = "c=biws,r=" + nonce;   // biws = base64("n,,"): no channel binding
        String authMessage = clientFirstBare + "," + serverFirst + "," + clientFinalWithoutProof;

        byte[] saltedPassword = hi(password.getBytes(StandardCharsets.UTF_8), Base64.getDecoder().decode(salt), iterations);
        byte[] clientKey = hmac(saltedPassword, "Client Key".getBytes(StandardCharsets.US_ASCII));
        byte[] storedKey = MessageDigest.getInstance("SHA-256").digest(clientKey);
        byte[] clientSignature = hmac(storedKey, authMessage.getBytes(StandardCharsets.UTF_8));
        byte[] proof = new byte[clientKey.length];
        for (int i = 0; i < proof.length; i++) proof[i] = (byte) (clientKey[i] ^ clientSignature[i]);

        byte[] serverKey = hmac(saltedPassword, "Server Key".getBytes(StandardCharsets.US_ASCII));
        expectedServerSignature = hmac(serverKey, authMessage.getBytes(StandardCharsets.UTF_8));
        String clientFinal = clientFinalWithoutProof + ",p=" + Base64.getEncoder().encodeToString(proof);
        return clientFinal.getBytes(StandardCharsets.US_ASCII);
    }

    /** Checks the server-final message "v=signature": proof that the server knows the password too. */
    void verifyServerFinal(String serverFinal) throws GeneralSecurityException {
        if (!serverFinal.startsWith("v=") || expectedServerSignature == null
                || !MessageDigest.isEqual(Base64.getDecoder().decode(serverFinal.substring(2)), expectedServerSignature)) {
            throw new GeneralSecurityException("SCRAM server signature mismatch");
        }
    }

    /** Hi() from RFC 5802: PBKDF2 with HMAC-SHA-256 and one output block. */
    private static byte[] hi(byte[] password, byte[] salt, int iterations) throws GeneralSecurityException {
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(password, "HmacSHA256"));
        mac.update(salt);
        mac.update(new byte[] {0, 0, 0, 1});
        byte[] u = mac.doFinal();
        byte[] result = u.clone();
        for (int i = 1; i < iterations; i++) {
            u = mac.doFinal(u);
            for (int j = 0; j < result.length; j++) result[j] ^= u[j];
        }
        return result;
    }

    private static byte[] hmac(byte[] key, byte[] data) throws GeneralSecurityException {
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(key, "HmacSHA256"));
        return mac.doFinal(data);
    }
}
