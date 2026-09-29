package com.marcelocunha.cunhatools.pfs;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;

// Protocol constants shared with the Swift side; see tools/pair-file-sharing/PROTOCOL.md.
public final class Wire {
    private Wire() {}

    public static final int VERSION = 1;
    public static final int ROLE_MAC = 1;
    public static final int ROLE_PHONE = 2;
    public static final int MAC_PORT = 47830;
    public static final int PHONE_PORT = 47831;
    public static final String SERVICE_TYPE = "_cunhapfs._tcp";

    public static final int MAX_DATA = 1 << 20;
    public static final int MAX_PLAIN = MAX_DATA + 64;
    public static final int TAG = 16;
    public static final int HEAD = 4;
    public static final int BLOCK = 8 << 20;
    public static final int CONNECTIONS = 4;
    public static final int SEGMENT_HEADER = 16;
    public static final int HANDSHAKE_TIMEOUT_MS = 10_000;
    public static final int IO_TIMEOUT_MS = 30_000;

    public static final byte INFO = 0x01;
    public static final byte OFFER = 0x02;
    public static final byte OFFER_MORE = 0x03;
    public static final byte JOIN = 0x04;
    public static final byte DATA = 0x05;
    public static final byte FINISH = 0x06;
    public static final byte CANCEL = 0x07;
    public static final byte ACCEPT = 0x10;
    public static final byte REJECT = 0x11;
    public static final byte DONE = 0x12;

    public static void putString(ByteBuffer buffer, String value) {
        byte[] bytes = value.getBytes(StandardCharsets.UTF_8);
        if (bytes.length > 0xFFFF) throw new IllegalArgumentException("texto longo demais");
        buffer.putShort((short) bytes.length);
        buffer.put(bytes);
    }

    public static String getString(ByteBuffer buffer) {
        int length = buffer.getShort() & 0xFFFF;
        byte[] bytes = new byte[length];
        buffer.get(bytes);
        return new String(bytes, StandardCharsets.UTF_8);
    }

    public static int stringSize(String value) {
        return 2 + value.getBytes(StandardCharsets.UTF_8).length;
    }

    static void putInt(byte[] b, int at, int v) {
        b[at] = (byte) (v >>> 24);
        b[at + 1] = (byte) (v >>> 16);
        b[at + 2] = (byte) (v >>> 8);
        b[at + 3] = (byte) v;
    }

    static void putLong(byte[] b, int at, long v) {
        putInt(b, at, (int) (v >>> 32));
        putInt(b, at + 4, (int) v);
    }

    static int getInt(byte[] b, int at) {
        return ((b[at] & 0xFF) << 24) | ((b[at + 1] & 0xFF) << 16) | ((b[at + 2] & 0xFF) << 8) | (b[at + 3] & 0xFF);
    }

    static long getLong(byte[] b, int at) {
        return ((long) getInt(b, at) << 32) | (getInt(b, at + 4) & 0xFFFFFFFFL);
    }
}
