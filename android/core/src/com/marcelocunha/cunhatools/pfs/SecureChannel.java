package com.marcelocunha.cunhatools.pfs;

import java.io.Closeable;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.security.GeneralSecurityException;
import java.security.MessageDigest;
import java.util.Arrays;
import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

// One authenticated TCP connection: HMAC challenge-response, then AES-256-GCM frames.
public final class SecureChannel implements Closeable {
    public interface KeyLookup {
        byte[] find(byte[] keyId);
    }

    public static final class AuthException extends IOException {
        private static final long serialVersionUID = 1L;

        public AuthException(String message) {
            super(message);
        }
    }

    private static final byte[] MAGIC = {'C', 'P', 'F', 'S'};
    private static final int HELLO_SIZE = 46;
    private static final int WELCOME_SIZE = 70;
    private static final int PROOF_SIZE = 32;

    // Kernel socket buffer in bytes; 0 keeps kernel autotuning (Linux turns it off once SO_RCVBUF is set).
    public static volatile int socketBuffer = 0;

    private final Socket socket;
    private final InputStream in;
    private final OutputStream out;
    private final Cipher encryptor;
    private final Cipher decryptor;
    private final SecretKeySpec sendKey;
    private final SecretKeySpec receiveKey;
    private final byte[] sendNonce = new byte[12];
    private final byte[] receiveNonce = new byte[12];
    private final byte[] header = new byte[Wire.HEAD];
    private long sendCounter;
    private long receiveCounter;
    private byte[] outBuffer = new byte[Wire.HEAD + 4096 + Wire.TAG];
    private byte[] inBuffer = new byte[4096 + Wire.TAG];
    public final int peerRole;
    public final byte[] keyId;

    private SecureChannel(Socket socket, byte[] key, byte[] salt, boolean client, int peerRole, byte[] keyId) throws IOException {
        this.socket = socket;
        this.in = socket.getInputStream();
        this.out = socket.getOutputStream();
        this.peerRole = peerRole;
        this.keyId = keyId;
        byte[] c2s = Keys.hkdf(key, salt, "cpfs c2s");
        byte[] s2c = Keys.hkdf(key, salt, "cpfs s2c");
        sendKey = new SecretKeySpec(client ? c2s : s2c, "AES");
        receiveKey = new SecretKeySpec(client ? s2c : c2s, "AES");
        try {
            encryptor = Cipher.getInstance("AES/GCM/NoPadding");
            decryptor = Cipher.getInstance("AES/GCM/NoPadding");
        } catch (GeneralSecurityException e) {
            throw new IOException(e);
        }
        socket.setSoTimeout(Wire.IO_TIMEOUT_MS);
    }

    public static SecureChannel connect(InetSocketAddress address, int timeoutMs, byte[] key, int role) throws IOException {
        return connect(address, timeoutMs, key, Keys.keyId(key), role);
    }

    // The keyId override exists so tests can present a known id with the wrong key.
    public static SecureChannel connect(InetSocketAddress address, int timeoutMs, byte[] key, byte[] keyId, int role) throws IOException {
        Socket socket = new Socket();
        try {
            tune(socket);
            socket.connect(address, timeoutMs);
            socket.setSoTimeout(Wire.HANDSHAKE_TIMEOUT_MS);
            return clientHandshake(socket, key, keyId, role);
        } catch (IOException | RuntimeException e) {
            closeQuietly(socket);
            throw e;
        }
    }

    public static SecureChannel accept(Socket socket, KeyLookup keys, int role) throws IOException {
        tune(socket);
        socket.setSoTimeout(Wire.HANDSHAKE_TIMEOUT_MS);
        InputStream in = socket.getInputStream();
        byte[] hello = new byte[HELLO_SIZE];
        readFully(in, hello, 0, HELLO_SIZE);
        checkPreamble(hello);
        byte[] keyId = Arrays.copyOfRange(hello, 6, 14);
        byte[] key = keys.find(keyId);
        if (key == null) throw new AuthException("chave de pareamento desconhecida");
        byte[] welcome = new byte[WELCOME_SIZE];
        System.arraycopy(MAGIC, 0, welcome, 0, 4);
        welcome[4] = (byte) Wire.VERSION;
        welcome[5] = (byte) role;
        System.arraycopy(Keys.random(32), 0, welcome, 6, 32);
        byte[] transcript = transcript(hello, welcome);
        System.arraycopy(Keys.hmac(key, Keys.utf8("cpfs-s"), transcript), 0, welcome, 38, 32);
        OutputStream out = socket.getOutputStream();
        out.write(welcome);
        out.flush();
        byte[] proof = new byte[PROOF_SIZE];
        readFully(in, proof, 0, PROOF_SIZE);
        if (!MessageDigest.isEqual(proof, Keys.hmac(key, Keys.utf8("cpfs-c"), transcript))) throw new AuthException("prova de pareamento inválida");
        return new SecureChannel(socket, key, salt(hello, welcome), false, hello[5], keyId);
    }

    private static SecureChannel clientHandshake(Socket socket, byte[] key, byte[] keyId, int role) throws IOException {
        byte[] hello = new byte[HELLO_SIZE];
        System.arraycopy(MAGIC, 0, hello, 0, 4);
        hello[4] = (byte) Wire.VERSION;
        hello[5] = (byte) role;
        System.arraycopy(keyId, 0, hello, 6, 8);
        System.arraycopy(Keys.random(32), 0, hello, 14, 32);
        OutputStream out = socket.getOutputStream();
        out.write(hello);
        out.flush();
        byte[] welcome = new byte[WELCOME_SIZE];
        try {
            readFully(socket.getInputStream(), welcome, 0, WELCOME_SIZE);
        } catch (EOFException e) {
            throw new AuthException("o destino não reconhece este pareamento");
        }
        checkPreamble(welcome);
        byte[] transcript = transcript(hello, welcome);
        byte[] expected = Keys.hmac(key, Keys.utf8("cpfs-s"), transcript);
        if (!MessageDigest.isEqual(expected, Arrays.copyOfRange(welcome, 38, 70))) throw new AuthException("a chave de pareamento não confere");
        out.write(Keys.hmac(key, Keys.utf8("cpfs-c"), transcript));
        out.flush();
        return new SecureChannel(socket, key, salt(hello, welcome), true, welcome[5], keyId);
    }

    private static void checkPreamble(byte[] message) throws IOException {
        for (int i = 0; i < 4; i++) if (message[i] != MAGIC[i]) throw new IOException("protocolo desconhecido");
        if (message[4] != Wire.VERSION) throw new IOException("versão de protocolo incompatível: " + message[4]);
    }

    private static byte[] transcript(byte[] hello, byte[] welcome) {
        byte[] t = new byte[HELLO_SIZE + 38];
        System.arraycopy(hello, 0, t, 0, HELLO_SIZE);
        System.arraycopy(welcome, 0, t, HELLO_SIZE, 38);
        return t;
    }

    private static byte[] salt(byte[] hello, byte[] welcome) {
        byte[] s = new byte[64];
        System.arraycopy(hello, 14, s, 0, 32);
        System.arraycopy(welcome, 6, s, 32, 32);
        return s;
    }

    private static void tune(Socket socket) throws IOException {
        socket.setTcpNoDelay(true);
        int size = socketBuffer;
        if (size > 0) {
            socket.setSendBufferSize(size);
            socket.setReceiveBufferSize(size);
        }
    }

    // Plaintext starts at Wire.HEAD; the array also holds the length prefix and the tag.
    public byte[] outBuffer(int plainCapacity) {
        int needed = Wire.HEAD + plainCapacity + Wire.TAG;
        if (outBuffer.length < needed) outBuffer = new byte[needed];
        return outBuffer;
    }

    public void sendFrame(int plainLength) throws IOException {
        if (plainLength > Wire.MAX_PLAIN) throw new IOException("quadro grande demais");
        int sealed = plainLength + Wire.TAG;
        Wire.putInt(outBuffer, 0, sealed);
        nonce(sendNonce, sendCounter++);
        try {
            encryptor.init(Cipher.ENCRYPT_MODE, sendKey, new GCMParameterSpec(128, sendNonce));
            encryptor.updateAAD(outBuffer, 0, Wire.HEAD);
            encryptor.doFinal(outBuffer, Wire.HEAD, plainLength, outBuffer, Wire.HEAD);
        } catch (GeneralSecurityException e) {
            throw new IOException(e);
        }
        out.write(outBuffer, 0, Wire.HEAD + sealed);
    }

    // Returns the plaintext length in inBuffer(), or -1 when the peer closed cleanly between frames.
    public int receiveFrame() throws IOException {
        int first = in.read();
        if (first < 0) return -1;
        header[0] = (byte) first;
        readFully(in, header, 1, 3);
        int sealed = Wire.getInt(header, 0);
        if (sealed < Wire.TAG || sealed > Wire.MAX_PLAIN + Wire.TAG) throw new IOException("quadro inválido");
        if (inBuffer.length < sealed) inBuffer = new byte[Wire.MAX_PLAIN + Wire.TAG];
        readFully(in, inBuffer, 0, sealed);
        nonce(receiveNonce, receiveCounter++);
        try {
            decryptor.init(Cipher.DECRYPT_MODE, receiveKey, new GCMParameterSpec(128, receiveNonce));
            decryptor.updateAAD(header, 0, Wire.HEAD);
            return decryptor.doFinal(inBuffer, 0, sealed, inBuffer, 0);
        } catch (GeneralSecurityException e) {
            throw new IOException("quadro adulterado ou fora de ordem", e);
        }
    }

    public byte[] inBuffer() {
        return inBuffer;
    }

    public String remoteHost() {
        return socket.getInetAddress() == null ? null : socket.getInetAddress().getHostAddress();
    }

    // Unblocks a thread stuck in read or write; the owner still calls close().
    public void abort() {
        try {
            socket.shutdownInput();
        } catch (IOException ignored) {
        }
        try {
            socket.shutdownOutput();
        } catch (IOException ignored) {
        }
        closeQuietly(socket);
    }

    @Override
    public void close() {
        closeQuietly(socket);
    }

    private static void nonce(byte[] nonce, long counter) {
        Wire.putLong(nonce, 4, counter);
    }

    static void readFully(InputStream in, byte[] b, int off, int len) throws IOException {
        while (len > 0) {
            int n = in.read(b, off, len);
            if (n < 0) throw new EOFException("conexão encerrada no meio de um quadro");
            off += n;
            len -= n;
        }
    }

    static void closeQuietly(Closeable c) {
        try {
            if (c != null) c.close();
        } catch (IOException ignored) {
        }
    }
}
