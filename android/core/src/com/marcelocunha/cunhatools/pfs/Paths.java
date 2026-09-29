package com.marcelocunha.cunhatools.pfs;

import java.io.IOException;

// Relative path hygiene: no absolute paths, no "..", no empty or control-character names.
public final class Paths {
    private Paths() {}

    public static String clean(String raw) throws IOException {
        StringBuilder out = new StringBuilder();
        for (String part : raw.replace('\\', '/').split("/")) {
            if (part.isEmpty() || part.equals(".")) continue;
            if (part.equals("..")) throw new IOException("caminho inválido: " + raw);
            StringBuilder name = new StringBuilder();
            for (int i = 0; i < part.length(); i++) {
                char c = part.charAt(i);
                name.append(c < 0x20 || c == ':' ? '_' : c);
            }
            if (out.length() > 0) out.append('/');
            out.append(name);
        }
        if (out.length() == 0) throw new IOException("caminho vazio");
        return out.toString();
    }

    public static String topLevel(String path) {
        int slash = path.indexOf('/');
        return slash < 0 ? path : path.substring(0, slash);
    }

    // Two manifest items with the same path would share a temp file; the later one gets " (2)", " (3)"...
    public static String unique(String path, java.util.Set<String> taken, boolean directory) {
        if (taken.add(path)) return path;
        int slash = path.lastIndexOf('/');
        String parent = slash < 0 ? "" : path.substring(0, slash + 1);
        String name = path.substring(slash + 1);
        for (int n = 2; ; n++) {
            String candidate = parent + numbered(name, n, directory);
            if (taken.add(candidate)) return candidate;
        }
    }

    // "foto.jpg" -> "foto (2).jpg"; folders and names without an extension get the suffix at the end.
    public static String numbered(String name, int n, boolean directory) {
        int dot = directory ? -1 : name.lastIndexOf('.');
        if (dot <= 0) return name + " (" + n + ")";
        return name.substring(0, dot) + " (" + n + ")" + name.substring(dot);
    }
}
