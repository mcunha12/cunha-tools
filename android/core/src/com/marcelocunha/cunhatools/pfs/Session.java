package com.marcelocunha.cunhatools.pfs;

import java.io.IOException;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicLongArray;

// One incoming transfer: the manifest, the files being written and the connections feeding them.
public final class Session {
    public final String id;
    public final Peer peer;
    public final Entry[] entries;
    public final long total;
    public final long startedAt = System.nanoTime();
    public Object sinkState;

    private final Server.Sink sink;
    private final Server.Events events;
    private final Server.Target[] targets;
    private final boolean[] committed;
    private final AtomicLongArray remaining;
    private final AtomicLong received = new AtomicLong();
    private final AtomicBoolean ended = new AtomicBoolean();
    private final List<SecureChannel> channels = new CopyOnWriteArrayList<>();
    private volatile String failure;
    private volatile long lastProgress = System.nanoTime();

    Session(String id, Peer peer, Entry[] entries, long total, Server.Sink sink, Server.Events events) {
        this.id = id;
        this.peer = peer;
        this.entries = entries;
        this.total = total;
        this.sink = sink;
        this.events = events;
        this.targets = new Server.Target[entries.length];
        this.committed = new boolean[entries.length];
        this.remaining = new AtomicLongArray(entries.length);
        for (int i = 0; i < entries.length; i++) remaining.set(i, entries[i].size);
    }

    public long received() {
        return received.get();
    }

    public boolean isEnded() {
        return ended.get();
    }

    public void cancel() {
        fail("cancelado");
    }

    void attach(SecureChannel channel) throws IOException {
        channels.add(channel);
        if (failure != null) throw new IOException(failure);
    }

    // DATA payload: repeated [u32 file][u64 offset][u32 length][bytes].
    void write(byte[] buffer, int at, int end) throws IOException {
        while (at < end) {
            if (failure != null) throw new IOException(failure);
            if (end - at < Wire.SEGMENT_HEADER) throw new IOException("segmento truncado");
            int file = Wire.getInt(buffer, at);
            long offset = Wire.getLong(buffer, at + 4);
            int length = Wire.getInt(buffer, at + 12);
            at += Wire.SEGMENT_HEADER;
            if (file < 0 || file >= entries.length || length < 0 || length > end - at || offset < 0 || offset + length > entries[file].size) {
                throw new IOException("segmento fora do manifesto");
            }
            target(file).write(buffer, at, length, offset);
            at += length;
            long left = remaining.addAndGet(file, -length);
            if (left < 0) throw new IOException("dados duplicados");
            if (left == 0) commit(file);
            // Counted after the commit, so received == total means every file is already in place.
            received.addAndGet(length);
            lastProgress = System.nanoTime();
        }
    }

    private Server.Target target(int file) throws IOException {
        synchronized (targets) {
            if (failure != null) throw new IOException(failure);
            Server.Target target = targets[file];
            if (target == null) {
                target = sink.create(this, file);
                targets[file] = target;
            }
            return target;
        }
    }

    private void commit(int file) throws IOException {
        Server.Target target = target(file);
        target.commit();
        synchronized (targets) {
            committed[file] = true;
        }
    }

    // Waits for the other connections to drain, then writes empty files and folders.
    void complete() throws IOException {
        while (received.get() < total) {
            if (failure != null) throw new IOException(failure);
            if (System.nanoTime() - lastProgress > Wire.IO_TIMEOUT_MS * 1_000_000L) throw new IOException("dados incompletos");
            try {
                Thread.sleep(2);
            } catch (InterruptedException e) {
                throw new IOException("interrompido");
            }
        }
        for (int i = 0; i < entries.length; i++) {
            if (entries[i].directory) sink.directory(this, i);
            else if (entries[i].size == 0) commit(i);
        }
        if (ended.compareAndSet(false, true)) {
            sink.finish(this, true);
            events.ended(this, null);
        }
    }

    void fail(String reason) {
        if (ended.get() || failure != null) return;
        failure = reason;
        for (SecureChannel channel : channels) channel.abort();
        synchronized (targets) {
            for (int i = 0; i < targets.length; i++) {
                if (targets[i] != null && !committed[i]) targets[i].abort();
            }
        }
        if (ended.compareAndSet(false, true)) {
            sink.finish(this, false);
            events.ended(this, reason);
        }
    }
}
