namespace Conduit.Http;

/// <summary>Outcome of parsing the front of a receive buffer.</summary>
public enum ParseStatus {
    /// <summary>A whole request was parsed.</summary>
    Complete,
    /// <summary>The bytes so far are a valid prefix; wait for more.</summary>
    NeedMore,
    /// <summary>The bytes are not a valid request; answer 400 and close.</summary>
    Bad,
}

/// <summary>
/// One parsed request. Every span points into the receive buffer, which is reused after the
/// handler returns, so the handler copies whatever it keeps.
/// </summary>
public readonly ref struct HttpRequest {
    /// <summary>Creates a request over spans that point into the receive buffer.</summary>
    public HttpRequest(ReadOnlySpan<byte> method, ReadOnlySpan<byte> path, ReadOnlySpan<byte> query,
        ReadOnlySpan<byte> authorization, ReadOnlySpan<byte> body, bool keepAlive) {
        Method = method;
        Path = path;
        Query = query;
        Authorization = authorization;
        Body = body;
        KeepAlive = keepAlive;
    }

    /// <summary>The method token, such as GET.</summary>
    public ReadOnlySpan<byte> Method { get; }
    /// <summary>The request target before any '?', not decoded.</summary>
    public ReadOnlySpan<byte> Path { get; }
    /// <summary>The raw query text after '?', not decoded; empty when there is none.</summary>
    public ReadOnlySpan<byte> Query { get; }
    /// <summary>The Authorization header value, or empty.</summary>
    public ReadOnlySpan<byte> Authorization { get; }
    /// <summary>The body, exactly Content-Length bytes.</summary>
    public ReadOnlySpan<byte> Body { get; }
    /// <summary>True when the connection stays open after the response.</summary>
    public bool KeepAlive { get; }
}

/// <summary>Minimal HTTP/1.x request parser: request line, headers, body by Content-Length.</summary>
public static class HttpParser {
    /// <summary>Largest request head (line plus headers) accepted.</summary>
    public const int MaxHeadBytes = 64 * 1024;
    /// <summary>Largest body accepted.</summary>
    public const int MaxBodyBytes = 1024 * 1024;

    /// <summary>
    /// Tries to parse one request from the start of <paramref name="data"/>. On Complete,
    /// <paramref name="consumed"/> is the number of bytes the request used (head plus body).
    /// Transfer-Encoding is not supported and is answered as Bad.
    /// </summary>
    public static ParseStatus TryParse(ReadOnlySpan<byte> data, out HttpRequest request, out int consumed) {
        request = default;
        consumed = 0;

        int headEnd = data.IndexOf("\r\n\r\n"u8);
        if (headEnd < 0) {
            return data.Length > MaxHeadBytes ? ParseStatus.Bad : ParseStatus.NeedMore;
        }

        if (headEnd > MaxHeadBytes) {
            return ParseStatus.Bad;
        }

        ReadOnlySpan<byte> head = data[..headEnd];
        int lineEnd = head.IndexOf("\r\n"u8);
        ReadOnlySpan<byte> requestLine = lineEnd < 0 ? head : head[..lineEnd];

        // Request line: METHOD SP target SP HTTP/1.x
        int sp1 = requestLine.IndexOf((byte)' ');
        if (sp1 <= 0) {
            return ParseStatus.Bad;
        }

        ReadOnlySpan<byte> rest = requestLine[(sp1 + 1)..];
        int sp2 = rest.IndexOf((byte)' ');
        if (sp2 <= 0) {
            return ParseStatus.Bad;
        }

        ReadOnlySpan<byte> method = requestLine[..sp1];
        ReadOnlySpan<byte> target = rest[..sp2];
        ReadOnlySpan<byte> version = rest[(sp2 + 1)..];
        if (target[0] != (byte)'/') {
            return ParseStatus.Bad;
        }

        bool keepAlive;
        if (version.SequenceEqual("HTTP/1.1"u8)) {
            keepAlive = true;
        } else if (version.SequenceEqual("HTTP/1.0"u8)) {
            keepAlive = false;
        } else {
            return ParseStatus.Bad;
        }

        int q = target.IndexOf((byte)'?');
        ReadOnlySpan<byte> path = q < 0 ? target : target[..q];
        ReadOnlySpan<byte> query = q < 0 ? default : target[(q + 1)..];

        long contentLength = 0;
        bool haveLength = false;
        ReadOnlySpan<byte> authorization = default;

        ReadOnlySpan<byte> headers = lineEnd < 0 ? default : head[(lineEnd + 2)..];
        while (!headers.IsEmpty) {
            int eol = headers.IndexOf("\r\n"u8);
            ReadOnlySpan<byte> line = eol < 0 ? headers : headers[..eol];
            headers = eol < 0 ? default : headers[(eol + 2)..];

            int colon = line.IndexOf((byte)':');
            if (colon <= 0) {
                return ParseStatus.Bad;
            }

            ReadOnlySpan<byte> name = line[..colon];
            ReadOnlySpan<byte> value = Trim(line[(colon + 1)..]);

            if (EqualsIgnoreCase(name, "content-length"u8)) {
                if (haveLength || !TryParseLength(value, out contentLength)) {
                    return ParseStatus.Bad;
                }

                haveLength = true;
            } else if (EqualsIgnoreCase(name, "authorization"u8)) {
                authorization = value;
            } else if (EqualsIgnoreCase(name, "connection"u8)) {
                if (ContainsToken(value, "close"u8)) {
                    keepAlive = false;
                } else if (ContainsToken(value, "keep-alive"u8)) {
                    keepAlive = true;
                }
            } else if (EqualsIgnoreCase(name, "transfer-encoding"u8)) {
                return ParseStatus.Bad;
            }
        }

        if (contentLength > MaxBodyBytes) {
            return ParseStatus.Bad;
        }

        int bodyStart = headEnd + 4;
        int total = bodyStart + (int)contentLength;
        if (data.Length < total) {
            return ParseStatus.NeedMore;
        }

        request = new HttpRequest(method, path, query, authorization, data.Slice(bodyStart, (int)contentLength), keepAlive);
        consumed = total;
        return ParseStatus.Complete;
    }

    /// <summary>Parses 1 to 10 decimal digits. False for an empty value, a longer one or any other character.</summary>
    private static bool TryParseLength(ReadOnlySpan<byte> value, out long result) {
        result = 0;
        if (value.IsEmpty || value.Length > 10) {
            return false;
        }

        foreach (byte c in value) {
            if (c < (byte)'0' || c > (byte)'9') {
                return false;
            }

            result = result * 10 + (c - '0');
        }
        return true;
    }

    /// <summary>Removes leading and trailing spaces and tabs.</summary>
    private static ReadOnlySpan<byte> Trim(ReadOnlySpan<byte> s) {
        int start = 0;
        int end = s.Length;
        while (start < end && (s[start] == ' ' || s[start] == '\t')) {
            start++;
        }

        while (end > start && (s[end - 1] == ' ' || s[end - 1] == '\t')) {
            end--;
        }

        return s[start..end];
    }

    /// <summary>Compares ASCII text ignoring case; <paramref name="lower"/> must be lower case.</summary>
    private static bool EqualsIgnoreCase(ReadOnlySpan<byte> s, ReadOnlySpan<byte> lower) {
        if (s.Length != lower.Length) {
            return false;
        }

        for (int i = 0; i < s.Length; i++) {
            byte c = s[i];
            if (c >= 'A' && c <= 'Z') {
                c = (byte)(c + 32);
            }

            if (c != lower[i]) {
                return false;
            }
        }
        return true;
    }

    /// <summary>True when the comma-separated header value contains the (lower case) token.</summary>
    private static bool ContainsToken(ReadOnlySpan<byte> value, ReadOnlySpan<byte> lowerToken) {
        while (!value.IsEmpty) {
            int comma = value.IndexOf((byte)',');
            ReadOnlySpan<byte> part = Trim(comma < 0 ? value : value[..comma]);
            if (EqualsIgnoreCase(part, lowerToken)) {
                return true;
            }

            value = comma < 0 ? default : value[(comma + 1)..];
        }
        return false;
    }
}
