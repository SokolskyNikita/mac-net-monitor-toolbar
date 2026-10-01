// In-process ICMP echo, replacing a /sbin/ping process per target per cycle (six process
// launches every 3 seconds were most of NetMenu's CPU use).
//
// macOS lets unprivileged processes open SOCK_DGRAM/IPPROTO_ICMP sockets. On Darwin such a
// socket behaves like a raw one in two ways that matter here:
// - Received packets include the IPv4 header, so the reply's TTL (and from it the hop count
//   that tells a portal's local answer from the real target) is read as /sbin/ping did.
// - It receives every ICMP echo reply arriving at this Mac, including other processes' pings.
//   A reply is accepted only if its identifier, sequence number, source address and random
//   payload all match a request we sent, and its checksum is valid.
//
// One socket and one receiver thread serve all probes. RTT is the kernel's receive timestamp
// (SO_TIMESTAMP) minus the send time, like ping(8), cross-checked against the monotonic clock
// so a wall-clock change cannot produce a bogus value. If the socket cannot be created at all
// (e.g. blocked by policy), callers fall back to /sbin/ping.

import Darwin
import Foundation

final class ICMPPinger: @unchecked Sendable {
    static let shared = ICMPPinger()
    static let payloadSize = 16

    enum Result: Equatable {
        case reply(ms: Double, ttl: Int)
        case lost
        /// This Mac could not send the probe.
        case unmeasured(String)
        /// ICMP sockets are not available to this process; use /sbin/ping instead.
        case unavailable
    }

    private final class Waiter {
        let address: in_addr_t
        let payload: [UInt8]
        let sentWall: timeval
        let sentMono: TimeInterval
        let done = DispatchSemaphore(value: 0)
        var reply: (ms: Double, ttl: Int)?
        init(address: in_addr_t, payload: [UInt8], sentWall: timeval, sentMono: TimeInterval) {
            self.address = address; self.payload = payload; self.sentWall = sentWall; self.sentMono = sentMono
        }
    }

    private let lock = NSLock()
    private var fd: Int32 = -1
    /// Bumped whenever the socket is replaced, so a stale receiver thread exits.
    private var generation = 0
    private var permanentlyUnavailable = false
    private let identifier = UInt16.random(in: 1...UInt16.max)
    private var nextSequence = UInt16.random(in: 0...UInt16.max)
    private var waiters: [UInt16: Waiter] = [:]

    // MARK: - Probe

    func ping(_ address: in_addr, timeoutMs: Int) -> Result {
        guard let socket = ensureSocket() else {
            lock.lock(); let gone = permanentlyUnavailable; lock.unlock()
            return gone ? .unavailable : .unmeasured("no ICMP socket")
        }
        var payload = [UInt8](repeating: 0, count: Self.payloadSize)
        arc4random_buf(&payload, payload.count)

        lock.lock()
        var seq = nextSequence
        // Skip sequence numbers still awaiting replies (after a wrap).
        while waiters[seq] != nil { seq &+= 1 }
        nextSequence = seq &+ 1
        var wall = timeval(); gettimeofday(&wall, nil)
        let waiter = Waiter(address: address.s_addr, payload: payload, sentWall: wall, sentMono: BandwidthClock.now())
        waiters[seq] = waiter
        lock.unlock()
        defer { lock.lock(); if waiters[seq] === waiter { waiters[seq] = nil }; lock.unlock() }

        let packet = Self.echoRequest(identifier: identifier, sequence: seq, payload: payload)
        var to = sockaddr_in()
        to.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        to.sin_family = sa_family_t(AF_INET)
        to.sin_addr = address
        let sent = withUnsafePointer(to: &to) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(socket, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if sent != packet.count {
            let err = errno
            // No route, interface down: the network's problem, as ping(8) counts it.
            if [EHOSTUNREACH, ENETUNREACH, ENETDOWN, EHOSTDOWN, EADDRNOTAVAIL].contains(err) { return .lost }
            if err == EBADF || err == ENOTSOCK { resetSocket(ifGeneration: nil) }
            return .unmeasured("sendto: \(String(cString: strerror(err)))")
        }
        guard waiter.done.wait(timeout: .now() + .milliseconds(timeoutMs)) == .success,
              let reply = waiter.reply else { return .lost }
        return .reply(ms: reply.ms, ttl: reply.ttl)
    }

    // MARK: - Socket

    private func ensureSocket() -> Int32? {
        lock.lock(); defer { lock.unlock() }
        if fd >= 0 { return fd }
        if permanentlyUnavailable { return nil }
        let s = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard s >= 0 else {
            let err = errno
            if [EPERM, EACCES, EPROTONOSUPPORT, EAFNOSUPPORT].contains(err) {
                permanentlyUnavailable = true
                DiagLog.shared.warn("icmp", "ICMP sockets unavailable (\(String(cString: strerror(err)))); using /sbin/ping")
            } else {
                DiagLog.shared.warn("icmp", "cannot open ICMP socket: \(String(cString: strerror(err)))", throttleKey: "icmp-socket")
            }
            return nil
        }
        _ = fcntl(s, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_TIMESTAMP, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        // Every echo reply on this Mac arrives here; leave room for other processes' pings.
        var rcvbuf: Int32 = 256 * 1024
        setsockopt(s, SOL_SOCKET, SO_RCVBUF, &rcvbuf, socklen_t(MemoryLayout<Int32>.size))
        // Wake at least once a second so a replaced socket's thread notices and exits.
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        fd = s
        generation &+= 1
        let gen = generation
        let thread = Thread { [weak self] in self?.receiveLoop(socket: s, generation: gen) }
        thread.name = "netmenu.icmp"
        thread.qualityOfService = .userInitiated
        thread.start()
        return s
    }

    /// Closes the socket; the next probe opens a fresh one. The receiver thread owns the close.
    private func resetSocket(ifGeneration gen: Int?) {
        lock.lock(); defer { lock.unlock() }
        guard fd >= 0, gen == nil || gen == generation else { return }
        fd = -1
        generation &+= 1
    }

    private func isCurrent(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return gen == generation
    }

    private func receiveLoop(socket s: Int32, generation gen: Int) {
        defer { close(s) }
        var buffer = [UInt8](repeating: 0, count: 2048)
        var control = [UInt8](repeating: 0, count: 256)
        while isCurrent(gen) {
            var from = sockaddr_in()
            var iov = iovec()
            var msg = msghdr()
            let n: Int = buffer.withUnsafeMutableBytes { buf in
                control.withUnsafeMutableBytes { ctl in
                    withUnsafeMutablePointer(to: &from) { fromPtr in
                        withUnsafeMutablePointer(to: &iov) { iovPtr in
                            iovPtr.pointee.iov_base = buf.baseAddress
                            iovPtr.pointee.iov_len = buf.count
                            msg.msg_name = UnsafeMutableRawPointer(fromPtr)
                            msg.msg_namelen = socklen_t(MemoryLayout<sockaddr_in>.size)
                            msg.msg_iov = iovPtr
                            msg.msg_iovlen = 1
                            msg.msg_control = ctl.baseAddress
                            msg.msg_controllen = socklen_t(ctl.count)
                            return recvmsg(s, &msg, 0)
                        }
                    }
                }
            }
            let receivedMono = BandwidthClock.now()
            if n < 0 {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK || err == EINTR { continue }
                DiagLog.shared.warn("icmp", "recvmsg: \(String(cString: strerror(err))); reopening", throttleKey: "icmp-recv")
                resetSocket(ifGeneration: gen)
                return
            }
            guard let echo = Self.parseEchoReply(Array(buffer[0..<n])), echo.identifier == identifier else { continue }
            let kernelTime = Self.timestamp(control: control, length: Int(msg.msg_controllen))

            lock.lock()
            guard let waiter = waiters[echo.sequence], waiter.address == from.sin_addr.s_addr,
                  waiter.payload == echo.payload else { lock.unlock(); continue }
            waiters[echo.sequence] = nil
            lock.unlock()

            let mono = (receivedMono - waiter.sentMono) * 1000
            var ms = mono
            if let k = kernelTime {
                let kernel = Double(k.tv_sec - waiter.sentWall.tv_sec) * 1000
                    + Double(Int(k.tv_usec) - Int(waiter.sentWall.tv_usec)) / 1000
                // The kernel stamps arrival before this thread wakes, so it is the more precise
                // value, unless the wall clock moved in between.
                if kernel >= 0, kernel <= mono + 5 { ms = kernel }
            }
            waiter.reply = (max(0, ms), echo.ttl)
            waiter.done.signal()
        }
    }

    // MARK: - Packets (pure, tested)

    static func checksum(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var sum: UInt32 = 0
        var i = bytes.startIndex
        while i + 1 < bytes.endIndex {
            sum &+= UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
            i += 2
        }
        if i < bytes.endIndex { sum &+= UInt32(bytes[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum)
    }

    static func echoRequest(identifier: UInt16, sequence: UInt16, payload: [UInt8]) -> [UInt8] {
        var p: [UInt8] = [8, 0, 0, 0, UInt8(identifier >> 8), UInt8(identifier & 0xff),
                          UInt8(sequence >> 8), UInt8(sequence & 0xff)] + payload
        let c = checksum(p[...])
        p[2] = UInt8(c >> 8); p[3] = UInt8(c & 0xff)
        return p
    }

    struct EchoReply: Equatable {
        var identifier: UInt16
        var sequence: UInt16
        var ttl: Int
        var payload: [UInt8]
    }

    /// An IPv4 packet carrying a valid ICMP echo reply, or nil.
    static func parseEchoReply(_ packet: [UInt8]) -> EchoReply? {
        guard packet.count >= 20, packet[0] >> 4 == 4 else { return nil }
        let headerLength = Int(packet[0] & 0x0f) * 4
        guard headerLength >= 20, packet[9] == UInt8(IPPROTO_ICMP), packet.count >= headerLength + 8 else { return nil }
        let icmp = packet[headerLength...]
        let i = icmp.startIndex
        guard icmp[i] == 0, icmp[i + 1] == 0, checksum(icmp) == 0 else { return nil }
        return EchoReply(identifier: UInt16(icmp[i + 4]) << 8 | UInt16(icmp[i + 5]),
                         sequence: UInt16(icmp[i + 6]) << 8 | UInt16(icmp[i + 7]),
                         ttl: Int(packet[8]),
                         payload: Array(icmp[(i + 8)...]))
    }

    private static func timestamp(control: [UInt8], length: Int) -> timeval? {
        let headerSize = MemoryLayout<cmsghdr>.size
        var offset = 0
        while offset + headerSize <= min(length, control.count) {
            let header: cmsghdr = control.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: cmsghdr.self) }
            let len = Int(header.cmsg_len)
            guard len >= headerSize else { return nil }
            if header.cmsg_level == SOL_SOCKET, header.cmsg_type == SCM_TIMESTAMP,
               offset + headerSize + MemoryLayout<timeval>.size <= control.count {
                return control.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + headerSize, as: timeval.self) }
            }
            offset += (len + 3) & ~3  // CMSG_ALIGN: 4-byte alignment on Darwin
        }
        return nil
    }
}

/// IPv4 address for a ping target: a literal, or the first A record. Nil if it does not resolve.
func resolveIPv4(_ host: String) -> in_addr? {
    var addr = in_addr()
    if inet_pton(AF_INET, host, &addr) == 1 { return addr }
    var hints = addrinfo()
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_DGRAM
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
    defer { freeaddrinfo(result) }
    guard let sa = first.pointee.ai_addr, first.pointee.ai_family == AF_INET else { return nil }
    return sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
}
