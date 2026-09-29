package com.marcelocunha.cunhatools.pfs;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

// TCP listener: authenticates each connection, then serves INFO, OFFER (new transfer) or JOIN (extra connection).
public final class Server {
    public interface Sink {
        long usableSpace();

        Target create(Session session, int index) throws IOException;

        void directory(Session session, int index) throws IOException;

        void finish(Session session, boolean success);
    }

    public interface Target {
        void write(byte[] buffer, int offset, int length, long position) throws IOException;

        void commit() throws IOException;

        void abort();
    }

    public interface Events {
        void peer(Peer peer);

        void started(Session session);

        void ended(Session session, String error);
    }

    private final int port;
    private final SecureChannel.KeyLookup keys;
    private final int role;
    private final String id;
    private final String name;
    private final Sink sink;
    private final Events events;
    private final Map<String, Session> sessions = new ConcurrentHashMap<>();
    private volatile ServerSocket listener;

    public Server(int port, SecureChannel.KeyLookup keys, int role, String id, String name, Sink sink, Events events) {
        this.port = port;
        this.keys = keys;
        this.role = role;
        this.id = id;
        this.name = name;
        this.sink = sink;
        this.events = events;
    }

    public void start() throws IOException {
        ServerSocket socket = new ServerSocket();
        socket.setReuseAddress(true);
        if (SecureChannel.socketBuffer > 0) socket.setReceiveBufferSize(SecureChannel.socketBuffer);
        socket.bind(new InetSocketAddress(port), 16);
        listener = socket;
        Thread thread = new Thread(() -> acceptLoop(socket), "pfs-accept");
        thread.setDaemon(true);
        thread.start();
    }

    public int port() {
        ServerSocket socket = listener;
        return socket == null ? port : socket.getLocalPort();
    }

    public void close() {
        SecureChannel.closeQuietly(listener);
        listener = null;
        for (Session session : sessions.values()) session.fail("serviço encerrado");
    }

    public List<Session> sessions() {
        return new ArrayList<>(sessions.values());
    }

    private void acceptLoop(ServerSocket socket) {
        while (!socket.isClosed()) {
            try {
                Socket connection = socket.accept();
                Thread thread = new Thread(() -> handle(connection), "pfs-conn");
                thread.setDaemon(true);
                thread.start();
            } catch (IOException e) {
                if (socket.isClosed()) return;
            }
        }
    }

    private void handle(Socket socket) {
        SecureChannel channel = null;
        try {
            channel = SecureChannel.accept(socket, keys, role);
            int n = channel.receiveFrame();
            if (n < 1) return;
            ByteBuffer in = ByteBuffer.wrap(channel.inBuffer(), 0, n);
            byte type = in.get();
            if (type == Wire.INFO) info(channel, in);
            else if (type == Wire.OFFER) offer(channel, in);
            else if (type == Wire.JOIN) join(channel, in);
            else throw new IOException("mensagem inesperada");
        } catch (IOException ignored) {
            // A failed connection only matters through its session, which records the reason.
        } finally {
            if (channel != null) channel.close();
            else SecureChannel.closeQuietly(socket);
        }
    }

    private void info(SecureChannel channel, ByteBuffer in) throws IOException {
        String peerId = Wire.getString(in);
        String peerName = Wire.getString(in);
        int peerPort = in.getShort() & 0xFFFF;
        ByteBuffer out = ByteBuffer.wrap(channel.outBuffer(512), Wire.HEAD, 512);
        out.put(Wire.INFO);
        Wire.putString(out, id);
        Wire.putString(out, name);
        out.putShort((short) port());
        channel.sendFrame(out.position() - Wire.HEAD);
        events.peer(new Peer(peerId, peerName, channel.remoteHost(), peerPort, channel.keyId));
    }

    private void offer(SecureChannel channel, ByteBuffer in) throws IOException {
        byte[] sessionId = new byte[16];
        in.get(sessionId);
        in.get();
        String peerId = Wire.getString(in);
        String peerName = Wire.getString(in);
        int count = in.getInt();
        long total = in.getLong();
        if (count <= 0 || count > 1_000_000 || total < 0) throw new IOException("manifesto inválido");
        Entry[] entries = new Entry[count];
        java.util.Set<String> taken = new java.util.HashSet<>();
        int index = 0;
        long sum = 0;
        while (true) {
            int inFrame = in.getInt();
            for (int i = 0; i < inFrame && index < count; i++) {
                Entry entry = Entry.decode(in);
                entry = entry.withPath(Paths.unique(entry.path, taken, entry.directory));
                entries[index] = entry;
                sum += entries[index++].size;
            }
            if (index >= count) break;
            int n = channel.receiveFrame();
            if (n < 1) throw new IOException("manifesto incompleto");
            in = ByteBuffer.wrap(channel.inBuffer(), 0, n);
            if (in.get() != Wire.OFFER_MORE) throw new IOException("manifesto incompleto");
        }
        if (sum != total) throw new IOException("manifesto inconsistente");
        Peer peer = new Peer(peerId, peerName, channel.remoteHost(), 0, channel.keyId);
        events.peer(peer);
        if (sink.usableSpace() >= 0 && sink.usableSpace() < total) {
            reject(channel, "sem espaço no destino");
            return;
        }
        Session session = new Session(Keys.hex(sessionId), peer, entries, total, sink, events);
        sessions.put(session.id, session);
        try {
            session.attach(channel);
            reply(channel, Wire.ACCEPT);
            events.started(session);
            receive(channel, session, true);
        } catch (IOException e) {
            session.fail(e.getMessage() == null ? "conexão perdida" : e.getMessage());
            throw e;
        } finally {
            sessions.remove(session.id);
        }
    }

    private void join(SecureChannel channel, ByteBuffer in) throws IOException {
        byte[] sessionId = new byte[16];
        in.get(sessionId);
        Session session = sessions.get(Keys.hex(sessionId));
        if (session == null || session.isEnded()) {
            reject(channel, "transferência desconhecida");
            return;
        }
        try {
            session.attach(channel);
            reply(channel, Wire.ACCEPT);
            receive(channel, session, false);
        } catch (IOException e) {
            session.fail(e.getMessage() == null ? "conexão perdida" : e.getMessage());
            throw e;
        }
    }

    private void receive(SecureChannel channel, Session session, boolean control) throws IOException {
        while (true) {
            int n = channel.receiveFrame();
            if (n < 0) {
                if (control) throw new IOException("o remetente encerrou a conexão");
                return;
            }
            byte[] buffer = channel.inBuffer();
            byte type = n > 0 ? buffer[0] : 0;
            if (type == Wire.DATA) {
                session.write(buffer, 1, n);
            } else if (type == Wire.FINISH && control) {
                try {
                    session.complete();
                } catch (IOException e) {
                    reject(channel, e.getMessage() == null ? "falha no destino" : e.getMessage());
                    throw e;
                }
                ByteBuffer out = ByteBuffer.wrap(channel.outBuffer(32), Wire.HEAD, 32);
                out.put(Wire.DONE).putInt(session.entries.length).putLong(session.total);
                channel.sendFrame(13);
                return;
            } else if (type == Wire.CANCEL) {
                throw new IOException("cancelado pelo remetente");
            } else {
                throw new IOException("mensagem inesperada");
            }
        }
    }

    private static void reply(SecureChannel channel, byte type) throws IOException {
        channel.outBuffer(16)[Wire.HEAD] = type;
        channel.sendFrame(1);
    }

    private static void reject(SecureChannel channel, String reason) throws IOException {
        ByteBuffer out = ByteBuffer.wrap(channel.outBuffer(512), Wire.HEAD, 512);
        out.put(Wire.REJECT);
        Wire.putString(out, reason);
        channel.sendFrame(out.position() - Wire.HEAD);
    }
}
