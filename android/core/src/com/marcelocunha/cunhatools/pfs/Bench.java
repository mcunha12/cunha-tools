package com.marcelocunha.cunhatools.pfs;

import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

// AES-256-GCM seal+open throughput on one core; on the phone: adb shell CLASSPATH=<apk> app_process / com.marcelocunha.cunhatools.pfs.Bench
public final class Bench {
    private Bench() {}

    public static void main(String[] args) throws Exception {
        SecretKeySpec key = new SecretKeySpec(Keys.random(32), "AES");
        Cipher seal = Cipher.getInstance("AES/GCM/NoPadding");
        Cipher open = Cipher.getInstance("AES/GCM/NoPadding");
        byte[] buffer = new byte[Wire.MAX_DATA + Wire.TAG];
        byte[] nonce = new byte[12];
        long counter = 0;
        for (int round = 0; round < 3; round++) {
            int frames = 256;
            long start = System.nanoTime();
            for (int i = 0; i < frames; i++) {
                Wire.putLong(nonce, 4, counter++);
                seal.init(Cipher.ENCRYPT_MODE, key, new GCMParameterSpec(128, nonce));
                int sealed = seal.doFinal(buffer, 0, Wire.MAX_DATA, buffer, 0);
                open.init(Cipher.DECRYPT_MODE, key, new GCMParameterSpec(128, nonce));
                open.doFinal(buffer, 0, sealed, buffer, 0);
            }
            double seconds = (System.nanoTime() - start) / 1e9;
            System.out.printf("AES-256-GCM seal+open (%s): %.0f MB/s%n", seal.getProvider().getName(), frames * (double) Wire.MAX_DATA / seconds / 1e6);
        }
    }
}
