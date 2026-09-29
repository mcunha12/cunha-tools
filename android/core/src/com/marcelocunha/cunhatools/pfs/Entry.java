package com.marcelocunha.cunhatools.pfs;

import java.nio.ByteBuffer;

// One manifest item: a file or an empty folder, with a '/'-separated relative path.
public final class Entry {
    public final String path;
    public final long size;
    public final long modified;
    public final boolean directory;

    public Entry(String path, long size, long modified, boolean directory) {
        this.path = path;
        this.size = directory ? 0 : size;
        this.modified = modified;
        this.directory = directory;
    }

    Entry withPath(String newPath) {
        return new Entry(newPath, size, modified, directory);
    }

    public String name() {
        int slash = path.lastIndexOf('/');
        return slash < 0 ? path : path.substring(slash + 1);
    }

    int encodedSize() {
        return 1 + Wire.stringSize(path) + 16;
    }

    void encode(ByteBuffer out) {
        out.put((byte) (directory ? 1 : 0));
        Wire.putString(out, path);
        out.putLong(size);
        out.putLong(modified);
    }

    static Entry decode(ByteBuffer in) throws java.io.IOException {
        boolean directory = in.get() == 1;
        String path = Paths.clean(Wire.getString(in));
        long size = in.getLong();
        long modified = in.getLong();
        if (size < 0) throw new java.io.IOException("tamanho inválido");
        return new Entry(path, size, modified, directory);
    }
}
