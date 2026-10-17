import Darwin
import Foundation

/// One connected datagram socket per IPv6 probe. The kernel checks the ICMPv6
/// checksum and source; a random payload, ID and sequence reject unrelated replies.
/// Scope IDs keep link-local router traffic on its physical interface, outside the VPN.
enum IPv6Pinger {
    // Darwin's RFC3542 constants are gated behind __APPLE_USE_RFC_3542 in in6.h
    // and are not imported by Swift's default Darwin module.
    private static let receiveHopLimitOption: Int32 = 37
    static let hopLimitControlType: Int32 = 47
    static func ping(_ host: String, timeoutMs: Int) -> Latency.PingOutcome {
        var hints = addrinfo()
        hints.ai_family = AF_INET6; hints.ai_socktype = SOCK_DGRAM; hints.ai_flags = AI_NUMERICHOST
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let address = result else {
            return .unmeasured("invalid IPv6 address")
        }
        defer { freeaddrinfo(result) }
        let fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6)
        guard fd >= 0 else { return .unmeasured("IPv6 ICMP socket unavailable") }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_TIMESTAMP, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, IPPROTO_IPV6, receiveHopLimitOption, &on, socklen_t(MemoryLayout<Int32>.size))
        guard connect(fd, address.pointee.ai_addr, address.pointee.ai_addrlen) == 0 else {
            return sendFailure(errno)
        }
        var packet = [UInt8](repeating: 0, count: 8 + ICMPPinger.payloadSize)
        arc4random_buf(&packet, packet.count)
        packet[0] = 128; packet[1] = 0; packet[2] = 0; packet[3] = 0
        var wall = timeval(); gettimeofday(&wall, nil)
        let start = BandwidthClock.now()
        guard send(fd, packet, packet.count, 0) == packet.count else { return sendFailure(errno) }
        let deadline = start + Double(timeoutMs) / 1000
        while true {
            let remaining = deadline - BandwidthClock.now()
            guard remaining > 0 else { return .lost }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(ceil(remaining * 1000)))
            if ready == 0 { return .lost }
            if ready < 0 {
                if errno == EINTR { continue }
                return .unmeasured("IPv6 poll failed")
            }
            var buffer = [UInt8](repeating: 0, count: 2048)
            var control = [UInt8](repeating: 0, count: 256)
            var iov = iovec()
            var msg = msghdr()
            let n = buffer.withUnsafeMutableBytes { buf in
                control.withUnsafeMutableBytes { ctl in
                    withUnsafeMutablePointer(to: &iov) { ptr in
                        ptr.pointee = iovec(iov_base: buf.baseAddress, iov_len: buf.count)
                        msg.msg_iov = ptr; msg.msg_iovlen = 1
                        msg.msg_control = ctl.baseAddress; msg.msg_controllen = socklen_t(ctl.count)
                        return recvmsg(fd, &msg, MSG_DONTWAIT)
                    }
                }
            }
            if n < 0 {
                if [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                return sendFailure(errno)
            }
            guard matchesReply(Array(buffer.prefix(n)), request: packet) else { continue }
            let mono = (BandwidthClock.now() - start) * 1000
            var ms = mono
            if let stamp = ICMPPinger.timestamp(control: control, length: Int(msg.msg_controllen)) {
                let kernel = Double(stamp.tv_sec - wall.tv_sec) * 1000
                    + Double(Int(stamp.tv_usec) - Int(wall.tv_usec)) / 1000
                if kernel >= 0, kernel <= mono + 5 { ms = kernel }
            }
            let hops = hopLimit(control: control, length: Int(msg.msg_controllen)).map(Latency.inferredHops)
            return .reply(Latency.EchoReply(ms: ms, hops: hops))
        }
    }

    /// IPv6 datagram sockets deliver the received hop limit as ancillary data.
    static func hopLimit(control: [UInt8], length: Int) -> Int? {
        let end = min(length, control.count), headerSize = MemoryLayout<cmsghdr>.size
        var offset = 0
        while offset + headerSize <= end {
            let header = control.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: cmsghdr.self) }
            let count = Int(header.cmsg_len)
            guard count >= headerSize, count <= end - offset else { return nil }
            if header.cmsg_level == IPPROTO_IPV6, header.cmsg_type == hopLimitControlType,
               count >= headerSize + MemoryLayout<Int32>.size {
                let value = control.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + headerSize, as: Int32.self) }
                return (0...255).contains(value) ? Int(value) : nil
            }
            offset += (count + 3) & ~3 // Darwin CMSG_ALIGN
        }
        return nil
    }

    static func matchesReply(_ reply: [UInt8], request: [UInt8]) -> Bool {
        reply.count == request.count && reply.count >= 8 && reply[0] == 129 && reply[1] == 0
            && reply[4...] == request[4...]
    }

    private static func sendFailure(_ error: Int32) -> Latency.PingOutcome {
        if [EHOSTUNREACH, ENETUNREACH, ENETDOWN, EHOSTDOWN, EADDRNOTAVAIL].contains(error) { return .lost }
        return .unmeasured("IPv6 socket: \(String(cString: strerror(error)))")
    }
}
