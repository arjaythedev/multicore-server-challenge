import Foundation
import Vapor

/// Timestamps are RFC 3339 in UTC with exactly 3 fractional digits, truncated
/// (not rounded), as required by the challenge spec.
func rfc3339ms(_ date: Date) -> String {
    let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded(.down))
    let truncated = Date(timeIntervalSince1970: Double(milliseconds) / 1000)

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
    return formatter.string(from: truncated)
}

/// `SLUGIFY(x)` from the reference SQL:
/// `trim(both '-' from lower(regexp_replace(x, '[^A-Za-z0-9]+', '-', 'g')))`.
func slugify(_ value: String) -> String {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
    var output = ""
    var previousWasSeparator = false

    for scalar in value.unicodeScalars {
        if allowed.contains(scalar) {
            output.unicodeScalars.append(scalar)
            previousWasSeparator = false
        } else if !previousWasSeparator {
            output.append("-")
            previousWasSeparator = true
        }
    }

    return output.trimmingCharacters(in: CharacterSet(charactersIn: "-")).lowercased()
}

/// Build a response with a JSON body and an explicit status.
func jsonResponse<T: Content>(_ status: HTTPStatus, _ value: T) throws -> Response {
    let response = Response(status: status)
    try response.content.encode(value, as: .json)
    return response
}

/// ASCII digits only, like the reference parser (no sign, spaces or decimals).
func parseUnsignedInteger(_ raw: String) -> Int? {
    guard !raw.isEmpty else { return nil }

    var value = 0
    for byte in raw.utf8 {
        guard byte >= 0x30, byte <= 0x39 else { return nil }
        let digit = Int(byte - 0x30)
        if value > (Int.max - digit) / 10 {
            return nil
        }
        value = value * 10 + digit
    }
    return value
}
