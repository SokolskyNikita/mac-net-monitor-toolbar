// Shared vocabulary for contracts used across components; keep one-off text near its owner.

enum Host {
    static let cloudflareDNS = "1.1.1.1"
    static let cloudflareDNS2 = "1.0.0.1"
    static let googleDNS = "8.8.8.8"
    static let quad9 = "9.9.9.9"
    static let cloudflare = "one.one.one.one"
    static let google = "google.com"
    static let speedTest = "speed.cloudflare.com"
}

enum URLPart {
    static let httpsScheme = "https://"
    static let speedDownPath = "/__down"
    static let speedUpPath = "/__up"
    static let bytesQuery = "bytes="

    static func speedDownURL(bytes: Int) -> String {
        "\(httpsScheme)\(Host.speedTest)\(speedDownPath)?\(bytesQuery)\(bytes)"
    }

    static var speedUpURL: String {
        "\(httpsScheme)\(Host.speedTest)\(speedUpPath)"
    }
}

enum NetType {
    static let offline = "offline"
    static let ethernet = "ethernet"
    static let wifi = "wifi"
    static let vpn = "vpn"
    static let tether = "tether"
}

enum PortName {
    static let wifi = "Wi-Fi"
    static let airPort = "AirPort"
    static let vpn = "VPN"
}

enum HTTPMethod {
    static let get = "GET"
    static let post = "POST"
}

/// HTTP measurement policy shared by curl and URLSession probes.
enum HTTPHeader {
    static let cacheControl = "Cache-Control"
    static let noCache = "no-cache"
    static let acceptEncoding = "Accept-Encoding"
    static let identityEncoding = "identity"
    static let cacheControlArgument = "\(cacheControl): \(noCache)"
    static let acceptEncodingArgument = "\(acceptEncoding): \(identityEncoding)"
}

/// nettop's external format, shared by the command and both parsers.
enum NettopFormat {
    static let interface = "interface"
    static let state = "state"
    static let bytesIn = "bytes_in"
    static let bytesOut = "bytes_out"
    static let packetsIn = "packets_in"
    static let packetsOut = "packets_out"
    static let byteColumns = [bytesIn, bytesOut]
    static let counterColumns = byteColumns + [packetsIn, packetsOut]
    static let requestedColumns = ([interface, state] + counterColumns).joined(separator: ",")
    static let headerPrefix = ",\(interface),\(state),"
    static let tcpPrefixes = ["tcp4 ", "tcp6 "]
    static let udpPrefixes = ["udp4 ", "udp6 "]
    /// QUIC (HTTP/3) connections get rows of their own on current macOS.
    static let quicPrefixes = ["quic4 ", "quic6 "]
    static let socketPrefixes = tcpPrefixes + udpPrefixes + quicPrefixes
    private static let endpointSeparator = "<->"

    /// Whether a row describes one connection rather than a process. Connection labels are
    /// "protocol local<->remote"; the separator also catches protocols added after these.
    static func isSocketRow(_ label: String) -> Bool {
        socketPrefixes.contains(where: label.hasPrefix) || label.contains(endpointSeparator)
    }

    /// Only TCP rows carry a connection state; everything else counts while it is listed.
    static func hasConnectionState(_ label: String) -> Bool { tcpPrefixes.contains(where: label.hasPrefix) }
    static let established = "Established"
    static let loopbackInterface = "lo0"
}
