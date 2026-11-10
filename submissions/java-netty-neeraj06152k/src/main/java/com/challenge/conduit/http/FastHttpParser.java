package com.challenge.conduit.http;

import java.nio.charset.StandardCharsets;

/**
 * High-performance, zero-allocation HTTP request query scanner.
 * Scans integers and strings directly via index offsets without regex or intermediate arrays.
 */
public final class FastHttpParser {

    public static String getPath(String uri) {
        int qIdx = uri.indexOf('?');
        return qIdx == -1 ? uri : uri.substring(0, qIdx);
    }

    /**
     * Extracts query parameter value with zero regex or String[] allocations.
     * Returns null if not present.
     */
    public static String getQueryParam(String uri, String param) {
        int qIdx = uri.indexOf('?');
        if (qIdx == -1) return null;

        int searchStart = qIdx + 1;
        int paramLen = param.length();
        int uriLen = uri.length();

        while (searchStart < uriLen) {
            // Check if parameter matches at current position
            if (uri.startsWith(param, searchStart) && 
                searchStart + paramLen < uriLen && 
                uri.charAt(searchStart + paramLen) == '=') {
                
                int valStart = searchStart + paramLen + 1;
                int ampIdx = uri.indexOf('&', valStart);
                int valEnd = (ampIdx == -1) ? uriLen : ampIdx;

                String raw = uri.substring(valStart, valEnd);
                return decodeUrlComponent(raw);
            }

            // Advance to next '&'
            int nextAmp = uri.indexOf('&', searchStart);
            if (nextAmp == -1) break;
            searchStart = nextAmp + 1;
        }

        return null;
    }

    /**
     * Parses pagination limit (default 20, valid 1..100) with zero heap object allocations.
     * Returns -1 if invalid.
     */
    public static int parseLimit(String uri) {
        return parseNonNegativeInt(uri, "limit", 20, 1, 100);
    }

    /**
     * Parses pagination offset (default 0, valid >= 0) with zero heap object allocations.
     * Returns -1 if invalid.
     */
    public static int parseOffset(String uri) {
        return parseNonNegativeInt(uri, "offset", 0, 0, Integer.MAX_VALUE);
    }

    private static int parseNonNegativeInt(String uri, String param, int defaultVal, int min, int max) {
        int qIdx = uri.indexOf('?');
        if (qIdx == -1) return defaultVal;

        int searchStart = qIdx + 1;
        int paramLen = param.length();
        int uriLen = uri.length();

        while (searchStart < uriLen) {
            if (uri.startsWith(param, searchStart) && 
                searchStart + paramLen < uriLen && 
                uri.charAt(searchStart + paramLen) == '=') {
                
                int valStart = searchStart + paramLen + 1;
                int ampIdx = uri.indexOf('&', valStart);
                int valEnd = (ampIdx == -1) ? uriLen : ampIdx;

                if (valStart >= valEnd) return -1; // empty parameter

                long num = 0;
                for (int i = valStart; i < valEnd; i++) {
                    char c = uri.charAt(i);
                    if (c < '0' || c > '9') return -1;
                    num = num * 10 + (c - '0');
                    if (num > max) return -1;
                }

                if (num < min) return -1;
                return (int) num;
            }

            int nextAmp = uri.indexOf('&', searchStart);
            if (nextAmp == -1) break;
            searchStart = nextAmp + 1;
        }

        return defaultVal;
    }

    private static String decodeUrlComponent(String s) {
        if (s.indexOf('%') == -1 && s.indexOf('+') == -1) {
            return s; // Fast path: no escaping
        }
        int len = s.length();
        byte[] bytes = new byte[len];
        int pos = 0;
        for (int i = 0; i < len; i++) {
            char c = s.charAt(i);
            if (c == '+') {
                bytes[pos++] = ' ';
            } else if (c == '%' && i + 2 < len) {
                int d1 = Character.digit(s.charAt(i + 1), 16);
                int d2 = Character.digit(s.charAt(i + 2), 16);
                if (d1 != -1 && d2 != -1) {
                    bytes[pos++] = (byte) ((d1 << 4) + d2);
                    i += 2;
                } else {
                    bytes[pos++] = (byte) c;
                }
            } else {
                bytes[pos++] = (byte) c;
            }
        }
        return new String(bytes, 0, pos, StandardCharsets.UTF_8);
    }

    public static String slugify(String title) {
        StringBuilder sb = new StringBuilder(title.length());
        boolean inDash = false;
        for (int i = 0; i < title.length(); i++) {
            char c = title.charAt(i);
            if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) {
                sb.append(c);
                inDash = false;
            } else if (c >= 'A' && c <= 'Z') {
                sb.append((char)(c + 32));
                inDash = false;
            } else {
                if (!inDash && sb.length() > 0) {
                    sb.append('-');
                    inDash = true;
                }
            }
        }
        while (sb.length() > 0 && sb.charAt(sb.length() - 1) == '-') {
            sb.setLength(sb.length() - 1);
        }
        return sb.toString();
    }
}
