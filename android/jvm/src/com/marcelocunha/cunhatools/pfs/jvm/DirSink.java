package com.marcelocunha.cunhatools.pfs.jvm;

import com.marcelocunha.cunhatools.pfs.Entry;
import com.marcelocunha.cunhatools.pfs.Paths;
import com.marcelocunha.cunhatools.pfs.Server;
import com.marcelocunha.cunhatools.pfs.Session;
import java.io.File;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.util.HashMap;
import java.util.Map;

// Receives into a folder: temp file per item, positional writes, rename on completion.
public final class DirSink implements Server.Sink {
    private final File root;

    public DirSink(File root) {
        this.root = root;
    }

    @Override
    public long usableSpace() {
        root.mkdirs();
        return root.getUsableSpace();
    }

    @Override
    public Server.Target create(Session session, int index) throws IOException {
        Entry entry = session.entries[index];
        File destination = destination(session, entry.path);
        File parent = destination.getParentFile();
        if (!parent.isDirectory() && !parent.mkdirs()) throw new IOException("não foi possível criar " + parent);
        File temp = new File(parent, "." + destination.getName() + ".pfs-" + session.id.substring(0, 8));
        RandomAccessFile file = new RandomAccessFile(temp, "rw");
        file.setLength(entry.size);
        return new FileTarget(file.getChannel(), temp, destination, entry.modified);
    }

    @Override
    public void directory(Session session, int index) throws IOException {
        File folder = destination(session, session.entries[index].path);
        if (!folder.isDirectory() && !folder.mkdirs()) throw new IOException("não foi possível criar " + folder);
    }

    @Override
    public void finish(Session session, boolean success) {}

    // Top-level names that already exist get " (2)", " (3)"...; the mapping holds for the whole session.
    private synchronized File destination(Session session, String path) {
        @SuppressWarnings("unchecked")
        Map<String, String> names = (Map<String, String>) session.sinkState;
        if (names == null) {
            names = new HashMap<>();
            session.sinkState = names;
        }
        String top = Paths.topLevel(path);
        String mapped = names.get(top);
        if (mapped == null) {
            boolean folder = path.length() > top.length();
            mapped = top;
            for (int n = 2; new File(root, mapped).exists() || names.containsValue(mapped); n++) mapped = Paths.numbered(top, n, folder);
            names.put(top, mapped);
        }
        return new File(root, mapped + path.substring(top.length()));
    }

    private static final class FileTarget implements Server.Target {
        private final FileChannel channel;
        private final File temp;
        private final File destination;
        private final long modified;
        private boolean done;

        FileTarget(FileChannel channel, File temp, File destination, long modified) {
            this.channel = channel;
            this.temp = temp;
            this.destination = destination;
            this.modified = modified;
        }

        @Override
        public void write(byte[] buffer, int offset, int length, long position) throws IOException {
            ByteBuffer data = ByteBuffer.wrap(buffer, offset, length);
            while (data.hasRemaining()) position += channel.write(data, position);
        }

        @Override
        public synchronized void commit() throws IOException {
            if (done) return;
            done = true;
            channel.close();
            if (!temp.renameTo(destination)) throw new IOException("não foi possível gravar " + destination);
            if (modified > 0) destination.setLastModified(modified);
        }

        @Override
        public synchronized void abort() {
            if (done) return;
            done = true;
            try {
                channel.close();
            } catch (IOException ignored) {
            }
            temp.delete();
        }
    }
}
