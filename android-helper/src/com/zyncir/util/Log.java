package com.zyncir.util;

/**
 * Minimal stderr logger for the app_process helper. Output is visible in the
 * foreground `adb shell` that launched the process. Replaces scrcpy's Ln in the
 * vendored files so we do not have to pull in scrcpy's full logging stack.
 *
 * PRIVACY INVARIANT: never log clipboard content. Log events, byte counts, or
 * exception messages only — never the copied text itself.
 */
public final class Log {

    private static final String TAG = "zyncir";

    private Log() {
        // not instantiable
    }

    public static void i(String msg) {
        System.err.println(TAG + ": " + msg);
    }

    public static void d(String msg) {
        System.err.println(TAG + " [d]: " + msg);
    }

    public static void e(String msg) {
        System.err.println(TAG + " [e]: " + msg);
    }

    public static void e(String msg, Throwable t) {
        System.err.println(TAG + " [e]: " + msg);
        t.printStackTrace();
    }
}
