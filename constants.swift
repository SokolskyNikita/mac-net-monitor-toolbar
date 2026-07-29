// Shared string constants — literals used ≥3×, plus all hosts / URL parts.

enum Host {
    static let cloudflareDNS = "1.1.1.1"
    static let googleDNS = "8.8.8.8"
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
