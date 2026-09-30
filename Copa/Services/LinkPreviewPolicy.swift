import Foundation
import Darwin

/// Decides which copied links Copa may load a preview for.
///
/// Loading a preview visits the page, and copying a link is not the same as opening it. So Copa
/// never loads:
/// - Addresses on this Mac or the local network (localhost, 192.168.x.x, router pages, intranet
///   names, or public names that point to them): a visit could change something on a device.
/// - Links that look single-use or secret (sign-in, password reset, verify, unsubscribe, or a
///   token in the address): a visit could use them up before the user opens them.
/// - Links with a user name or password in them.
enum LinkPreviewPolicy {

    /// Quick check on the link itself, before any network access.
    nonisolated static func allowsPreview(of url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.user(percentEncoded: true) == nil, url.password(percentEncoded: true) == nil,
              let host = normalizedHost(of: url) else { return false }
        return !isLocalName(host) && !isLocalAddressLiteral(host) && !looksSensitive(url)
    }

    /// Looks the host up and allows the preview only if every address it points to is public.
    /// Returns nil when the lookup fails (e.g. offline), so it can be tried again later.
    nonisolated static func resolvesToPublicAddresses(_ url: URL) async -> Bool? {
        guard let host = normalizedHost(of: url) else { return false }
        return await Task.detached(priority: .utility) { () -> Bool? in
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
            defer { freeaddrinfo(first) }
            var sawAddress = false
            for info in sequence(first: first, next: { $0.pointee.ai_next }) {
                guard let address = info.pointee.ai_addr else { continue }
                switch Int32(address.pointee.sa_family) {
                case AF_INET:
                    let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
                    if isLocal(ipv4: withUnsafeBytes(of: ip) { Array($0) }) { return false }
                case AF_INET6:
                    let ip = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                    if isLocal(ipv6: withUnsafeBytes(of: ip) { Array($0) }) { return false }
                default:
                    return false
                }
                sawAddress = true
            }
            return sawAddress
        }.value
    }

    // MARK: Host names

    nonisolated private static func normalizedHost(of url: URL) -> String? {
        guard var host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        while host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }

    nonisolated private static let localSuffixes = [
        ".localhost", ".local", ".localdomain", ".internal", ".intranet", ".lan", ".home",
        ".home.arpa", ".corp", ".private", ".test", ".invalid", ".example",
    ]

    /// Names that only mean something on this Mac or the local network. Names without a dot
    /// ("localhost", "router", "jenkins") are intranet names.
    nonisolated private static func isLocalName(_ host: String) -> Bool {
        !host.contains(".") && !host.contains(":") || localSuffixes.contains { host.hasSuffix($0) }
    }

    nonisolated private static func isLocalAddressLiteral(_ host: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return isLocal(ipv4: withUnsafeBytes(of: v4) { Array($0) }) }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 { return isLocal(ipv6: withUnsafeBytes(of: v6) { Array($0) }) }
        // Shorthand forms such as "127.1" or "2130706433" also reach local addresses.
        return host.allSatisfy { $0.isNumber || $0 == "." } || host.hasPrefix("0x")
    }

    /// Loopback, private, link-local, carrier-grade NAT, benchmarking, multicast and reserved ranges.
    nonisolated private static func isLocal(ipv4 b: [UInt8]) -> Bool {
        guard b.count == 4 else { return true }
        switch (b[0], b[1]) {
        case (0, _), (10, _), (127, _), (169, 254), (192, 168): return true
        case (100, 64...127), (172, 16...31), (198, 18...19): return true
        case (192, 0): return b[2] == 0 || b[2] == 2
        case (198, 51): return b[2] == 100
        case (203, 0): return b[2] == 113
        default: return b[0] >= 224
        }
    }

    nonisolated private static func isLocal(ipv6 b: [UInt8]) -> Bool {
        guard b.count == 16 else { return true }
        if b[0..<15].allSatisfy({ $0 == 0 }) { return true }                          // :: and ::1
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff {      // ::ffff:a.b.c.d
            return isLocal(ipv4: Array(b[12..<16]))
        }
        if b[0] == 0x00, b[1] == 0x64, b[2] == 0xff, b[3] == 0x9b {                    // 64:ff9b::a.b.c.d (NAT64)
            return isLocal(ipv4: Array(b[12..<16]))
        }
        if b[0] & 0xfe == 0xfc { return true }                                        // fc00::/7 unique local
        if b[0] == 0xfe && b[1] & 0xc0 == 0x80 { return true }                        // fe80::/10 link-local
        if b[0] == 0xff { return true }                                               // multicast
        if b[0] == 0x20, b[1] == 0x01, b[2] == 0x0d, b[3] == 0xb8 { return true }     // documentation
        return false
    }

    // MARK: Single-use and secret links

    /// Path words used by sign-in, reset, verification, invitation and unsubscribe links.
    nonisolated private static let sensitivePathWords: Set<String> = [
        "reset", "verify", "verification", "confirm", "confirmation", "activate", "activation",
        "unsubscribe", "optout", "magic", "magiclink", "login", "signin", "logout", "signout",
        "sso", "saml", "invite", "invitation", "accept", "approve", "authorize", "oauth", "oauth2",
        "callback", "token", "otp", "2fa", "mfa", "passwordless", "resetpassword", "forgotpassword",
    ]

    /// Query parameters that carry secrets or single-use codes.
    nonisolated private static let sensitiveParameters: Set<String> = [
        "code", "otp", "key", "apikey", "auth", "sig", "hmac", "jwt", "session", "sessionid", "sid",
        "ticket", "nonce", "pass", "pwd", "magic", "invite", "reset", "verify", "confirm",
        "samlresponse", "samlrequest", "credential", "x-amz-credential", "x-goog-credential",
    ]

    nonisolated private static let sensitiveParameterParts = ["token", "secret", "password", "signature", "auth_", "api_key", "apikey", "access_key"]

    nonisolated static func looksSensitive(_ url: URL) -> Bool {
        let path = url.path(percentEncoded: false).lowercased()
        for segment in path.split(separator: "/") {
            // "sign-in", "sign_in" and "signin" all count; so does "reset" inside "reset-password".
            let joined = segment.filter { $0 != "-" && $0 != "_" }
            if sensitivePathWords.contains(joined) { return true }
            let words = segment.split { !$0.isLetter && !$0.isNumber }
            if words.contains(where: { sensitivePathWords.contains(String($0)) }) { return true }
        }
        let names = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { $0.name.lowercased() } ?? []
        return names.contains { name in
            sensitiveParameters.contains(name) || sensitiveParameterParts.contains { name.contains($0) }
        }
    }
}
