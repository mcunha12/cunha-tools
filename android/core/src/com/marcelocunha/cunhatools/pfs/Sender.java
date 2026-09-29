package com.marcelocunha.cunhatools.pfs;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.nio.ByteBuffer;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;

// Sends a file set over N parallel secure connections; 8 MiB blocks of the concatenated stream go to whichever connection is free.
public final class Sender {
    public static final class Result {
        public final int files;
        public final long bytes;
        public final long nanos;

        Result(int files, long bytes, long nanos) {
            this.files = files;
            this.bytes = bytes;
            this.nanos = nanos;
        }

        public double megabytesPerSecond() {
            return nanos == 0 ? 0 : bytes / (nanos / 1e9) / 1e6;
        }
    }

    // The first connection failed, so the caller may try another address.
    public static final class UnreachableException extends IOException {
        private static final long serialVersionUID = 1L;

        UnreachableException(IOException cause) {
            super(cause.getMessage(), cause);
        }
    }

    private final byte[] key;
    private final int role;
    private final String id;
    private final String name;
    private final AtomicLong sent = new AtomicLong();
    private final AtomicReference<IOException> failure = new AtomicReference<>();
    private final List<SecureChannel> channels = new CopyOnWriteArrayList<>();
    private volatile long total;
    private volatile boolean cancelled;
    public int connectTimeoutMs = 2000;

    public Sender(byte[] key, int role, String id, String name) {
        this.key = key;
        this.role = role;
        this.id = id;
        this.name = name;
    }

    public long sent() {
        return sent.get();
    }

    public long total() {
        return total;
    }

    public void cancel() {
        cancelled = true;
        for (SecureChannel channel : channels) channel.abort();
    }

    // Connects and completes the INFO exchange; used to confirm a pairing and to check reachability.
    public static Peer info(InetSocketAddress address, int timeoutMs, byte[] key, int role, String id, String name, int port) throws IOException {
        try (SecureChannel channel = SecureChannel.connect(address, timeoutMs, key, role)) {
            ByteBuffer out = ByteBuffer.wrap(channel.outBuffer(512), Wire.HEAD, 512);
            out.put(Wire.INFO);
            Wire.putString(out, id);
            Wire.putString(out, name);
            out.putShort((short) port);
            channel.sendFrame(out.position() - Wire.HEAD);
            int n = channel.receiveFrame();
            if (n < 1) throw new IOException("o destino não respondeu");
            ByteBuffer in = ByteBuffer.wrap(channel.inBuffer(), 0, n);
            if (in.get() != Wire.INFO) throw new IOException("resposta inesperada");
            String peerId = Wire.getString(in);
            String peerName = Wire.getString(in);
            return new Peer(peerId, peerName, channel.remoteHost(), in.getShort() & 0xFFFF, channel.keyId);
        }
    }

    public Result send(InetSocketAddress address, List<Source> sources, int connections) throws IOException {
        long started = System.nanoTime();
        Plan plan = new Plan(sources);
        total = plan.total;
        byte[] session = Keys.random(16);
        SecureChannel control;
        try {
            control = open(address);
        } catch (SecureChannel.AuthException e) {
            throw e;
        } catch (IOException e) {
            throw new UnreachableException(e);
        }
        try {
            offer(control, session, plan, connections);
            expectAccept(control);
            AtomicInteger next = new AtomicInteger();
            int workers = (int) Math.max(1, Math.min(connections, plan.blocks));
            Thread[] threads = new Thread[workers - 1];
            for (int i = 0; i < threads.length; i++) {
                threads[i] = new Thread(() -> joinAndWork(address, session, plan, next), "pfs-send-" + (i + 1));
                threads[i].start();
            }
            try {
                work(control, plan, next);
            } catch (IOException e) {
                fail(e);
            }
            for (Thread thread : threads) joinQuietly(thread);
            throwIfFailed();
            ByteBuffer out = ByteBuffer.wrap(control.outBuffer(16), Wire.HEAD, 16);
            out.put(Wire.FINISH);
            control.sendFrame(1);
            int n = control.receiveFrame();
            if (n < 1) throw new IOException("o destino encerrou antes de confirmar");
            ByteBuffer in = ByteBuffer.wrap(control.inBuffer(), 0, n);
            byte type = in.get();
            if (type == Wire.REJECT) throw new IOException(Wire.getString(in));
            if (type != Wire.DONE) throw new IOException("resposta inesperada");
            return new Result(in.getInt(), in.getLong(), System.nanoTime() - started);
        } catch (IOException e) {
            if (cancelled) {
                sendCancel(control);
                throw new IOException("cancelado");
            }
            throw e;
        } finally {
            for (SecureChannel channel : channels) channel.abort();
            channels.clear();
        }
    }

    private SecureChannel open(InetSocketAddress address) throws IOException {
        if (cancelled) throw new IOException("cancelado");
        SecureChannel channel = SecureChannel.connect(address, connectTimeoutMs, key, role);
        channels.add(channel);
        if (cancelled) channel.abort();
        return channel;
    }

    private void offer(SecureChannel channel, byte[] session, Plan plan, int connections) throws IOException {
        byte[] buffer = channel.outBuffer(Wire.MAX_PLAIN);
        ByteBuffer out = ByteBuffer.wrap(buffer, Wire.HEAD, Wire.MAX_PLAIN);
        out.put(Wire.OFFER).put(session).put((byte) connections);
        Wire.putString(out, id);
        Wire.putString(out, name);
        out.putInt(plan.entries.length).putLong(plan.total);
        int index = 0;
        do {
            int countAt = out.position();
            out.putInt(0);
            int count = 0;
            while (index < plan.entries.length && out.remaining() >= plan.entries[index].encodedSize()) {
                plan.entries[index++].encode(out);
                count++;
            }
            if (count == 0 && index < plan.entries.length) throw new IOException("nome de arquivo longo demais");
            out.putInt(countAt, count);
            channel.sendFrame(out.position() - Wire.HEAD);
            out = ByteBuffer.wrap(buffer, Wire.HEAD, Wire.MAX_PLAIN);
            out.put(Wire.OFFER_MORE);
        } while (index < plan.entries.length);
    }

    private static void expectAccept(SecureChannel channel) throws IOException {
        int n = channel.receiveFrame();
        if (n < 1) throw new IOException("o destino recusou a conexão");
        ByteBuffer in = ByteBuffer.wrap(channel.inBuffer(), 0, n);
        byte type = in.get();
        if (type == Wire.REJECT) throw new IOException(Wire.getString(in));
        if (type != Wire.ACCEPT) throw new IOException("resposta inesperada");
    }

    private void joinAndWork(InetSocketAddress address, byte[] session, Plan plan, AtomicInteger next) {
        SecureChannel channel;
        try {
            channel = open(address);
            ByteBuffer out = ByteBuffer.wrap(channel.outBuffer(32), Wire.HEAD, 32);
            out.put(Wire.JOIN).put(session);
            channel.sendFrame(17);
            expectAccept(channel);
        } catch (IOException e) {
            return;
        }
        try {
            work(channel, plan, next);
        } catch (IOException e) {
            fail(e);
        }
    }

    private void work(SecureChannel channel, Plan plan, AtomicInteger next) throws IOException {
        byte[] buffer = channel.outBuffer(Wire.MAX_PLAIN);
        int limit = Wire.HEAD + Wire.MAX_PLAIN;
        Readers readers = new Readers(plan.sources);
        try {
            int block;
            while ((block = next.getAndIncrement()) < plan.blocks) {
                if (cancelled || failure.get() != null) return;
                long position = (long) block * Wire.BLOCK;
                long end = Math.min(plan.total, position + Wire.BLOCK);
                int file = plan.fileAt(position);
                while (position < end) {
                    int used = Wire.HEAD;
                    buffer[used++] = Wire.DATA;
                    long payload = 0;
                    while (position < end && limit - used > Wire.SEGMENT_HEADER) {
                        while (plan.start[file] + plan.size[file] <= position) file++;
                        long offset = position - plan.start[file];
                        int n = (int) Math.min(Math.min(end - position, plan.size[file] - offset), limit - used - Wire.SEGMENT_HEADER);
                        Wire.putInt(buffer, used, file);
                        Wire.putLong(buffer, used + 4, offset);
                        Wire.putInt(buffer, used + 12, n);
                        used += Wire.SEGMENT_HEADER;
                        readers.readFully(file, buffer, used, n, offset);
                        used += n;
                        position += n;
                        payload += n;
                    }
                    channel.sendFrame(used - Wire.HEAD);
                    sent.addAndGet(payload);
                }
            }
        } finally {
            readers.close();
        }
    }

    private void fail(IOException error) {
        if (failure.compareAndSet(null, error)) {
            for (SecureChannel channel : channels) channel.abort();
        }
    }

    private void throwIfFailed() throws IOException {
        if (cancelled) throw new IOException("cancelado");
        IOException error = failure.get();
        if (error != null) throw error;
    }

    private static void sendCancel(SecureChannel channel) {
        try {
            ByteBuffer.wrap(channel.outBuffer(16), Wire.HEAD, 16).put(Wire.CANCEL);
            channel.sendFrame(1);
        } catch (IOException ignored) {
        }
    }

    private static void joinQuietly(Thread thread) {
        try {
            thread.join();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    // The concatenated byte stream: file i covers [start[i], start[i] + size[i]).
    static final class Plan {
        final Source[] sources;
        final Entry[] entries;
        final long[] start;
        final long[] size;
        final long total;
        final long blocks;

        Plan(List<Source> list) {
            sources = list.toArray(new Source[0]);
            entries = new Entry[sources.length];
            start = new long[sources.length];
            size = new long[sources.length];
            long offset = 0;
            for (int i = 0; i < sources.length; i++) {
                entries[i] = sources[i].entry();
                start[i] = offset;
                size[i] = entries[i].size;
                offset += size[i];
            }
            total = offset;
            blocks = (total + Wire.BLOCK - 1) / Wire.BLOCK;
        }

        int fileAt(long position) {
            int low = 0;
            int high = start.length - 1;
            while (low < high) {
                int mid = (low + high + 1) >>> 1;
                if (start[mid] <= position) low = mid;
                else high = mid - 1;
            }
            return low;
        }
    }

    // Keeps the current file open while a connection walks through its block.
    private static final class Readers {
        private final Source[] sources;
        private int current = -1;
        private Source.Reader reader;

        Readers(Source[] sources) {
            this.sources = sources;
        }

        void readFully(int file, byte[] buffer, int offset, int length, long position) throws IOException {
            if (file != current) {
                close();
                reader = sources[file].open();
                current = file;
            }
            while (length > 0) {
                int n = reader.read(buffer, offset, length, position);
                if (n < 0) throw new IOException("o arquivo mudou durante o envio: " + sources[file].entry().path);
                offset += n;
                length -= n;
                position += n;
            }
        }

        void close() {
            SecureChannel.closeQuietly(reader);
            reader = null;
            current = -1;
        }
    }
}
