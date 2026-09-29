package com.marcelocunha.cunhatools;

import java.util.Locale;

final class Format {
    private Format() {}

    private static final Locale BR = new Locale("pt", "BR");

    static String bytes(long count) {
        if (count < 1000) return count + " B";
        String[] units = {"kB", "MB", "GB", "TB"};
        double value = count;
        int unit = -1;
        while (value >= 1000 && unit < units.length - 1) {
            value /= 1000;
            unit++;
        }
        return String.format(BR, value < 10 ? "%.1f %s" : "%.0f %s", value, units[unit]);
    }

    static String rate(double bytesPerSecond) {
        double mb = bytesPerSecond / 1e6;
        return String.format(BR, mb < 10 ? "%.1f MB/s" : "%.0f MB/s", mb);
    }

    static String duration(double seconds) {
        if (seconds < 90) return Math.max(1, Math.round(seconds)) + " s";
        return (long) (seconds / 60) + " min " + ((long) seconds % 60) + " s";
    }

    static String items(int count) {
        return count == 1 ? "1 item" : count + " itens";
    }
}
