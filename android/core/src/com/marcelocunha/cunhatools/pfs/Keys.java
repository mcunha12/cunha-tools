package com.marcelocunha.cunhatools.pfs;

import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Arrays;
import java.util.Base64;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

public final class Keys {
    private Keys() {}

    public static final int KEY_SIZE = 32;
    private static final SecureRandom RANDOM = new SecureRandom();

    public static byte[] random(int count) {
        byte[] bytes = new byte[count];
        RANDOM.nextBytes(bytes);
        return bytes;
    }

    public static String encode(byte[] bytes) {
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
    }

    public static byte[] decode(String text) {
        return Base64.getUrlDecoder().decode(text.trim());
    }

    public static String hex(byte[] bytes) {
        StringBuilder out = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) out.append(Character.forDigit((b >> 4) & 0xF, 16)).append(Character.forDigit(b & 0xF, 16));
        return out.toString();
    }

    // First 8 bytes of SHA-256(key): lets the listener pick the key before it proves anything.
    public static byte[] keyId(byte[] key) {
        try {
            return Arrays.copyOf(MessageDigest.getInstance("SHA-256").digest(key), 8);
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException(e);
        }
    }

    public static byte[] hmac(byte[] key, byte[]... parts) {
        try {
            Mac mac = Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(key, "HmacSHA256"));
            for (byte[] part : parts) mac.update(part);
            return mac.doFinal();
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException(e);
        }
    }

    // HKDF-SHA256 (RFC 5869) with one output block of 32 bytes.
    public static byte[] hkdf(byte[] inputKey, byte[] salt, String info) {
        byte[] prk = hmac(salt, inputKey);
        return hmac(prk, info.getBytes(StandardCharsets.UTF_8), new byte[] {1});
    }

    public static byte[] utf8(String text) {
        return text.getBytes(StandardCharsets.UTF_8);
    }
}
