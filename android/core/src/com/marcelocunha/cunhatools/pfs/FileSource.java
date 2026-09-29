package com.marcelocunha.cunhatools.pfs;

import java.io.File;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

public final class FileSource implements Source {
    private final File file;
    private final Entry entry;

    public FileSource(File file, String relativePath) {
        this.file = file;
        this.entry = new Entry(relativePath, file.isDirectory() ? 0 : file.length(), file.lastModified(), file.isDirectory());
    }

    @Override
    public Entry entry() {
        return entry;
    }

    @Override
    public Reader open() throws IOException {
        final FileChannel channel = new RandomAccessFile(file, "r").getChannel();
        return new Reader() {
            @Override
            public int read(byte[] buffer, int offset, int length, long position) throws IOException {
                return channel.read(ByteBuffer.wrap(buffer, offset, length), position);
            }

            @Override
            public void close() throws IOException {
                channel.close();
            }
        };
    }

    // Files and folders as dropped by the user; folders expand recursively, empty folders stay as entries.
    public static List<Source> collect(List<File> roots) {
        List<Source> out = new ArrayList<>();
        for (File root : roots) add(out, root, root.getName(), true);
        return out;
    }

    private static void add(List<Source> out, File file, String path, boolean root) {
        if (file.getName().equals(".DS_Store")) return;
        if (!root && java.nio.file.Files.isSymbolicLink(file.toPath())) return;
        if (!file.isDirectory()) {
            if (file.isFile()) out.add(new FileSource(file, path));
            return;
        }
        File[] children = file.listFiles();
        if (children == null || children.length == 0) {
            out.add(new FileSource(file, path));
            return;
        }
        Arrays.sort(children);
        for (File child : children) add(out, child, path + "/" + child.getName(), false);
    }
}
