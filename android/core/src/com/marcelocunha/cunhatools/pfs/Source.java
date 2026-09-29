package com.marcelocunha.cunhatools.pfs;

import java.io.Closeable;
import java.io.IOException;

// Something the sender can read by position: a file on the JVM, a content URI on Android.
public interface Source {
    Entry entry();

    Reader open() throws IOException;

    interface Reader extends Closeable {
        int read(byte[] buffer, int offset, int length, long position) throws IOException;
    }
}
