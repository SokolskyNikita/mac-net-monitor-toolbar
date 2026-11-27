import Darwin
import Foundation
import Testing
@testable import NetMenu

@Suite struct IPConnectivityTests {
    private func checks(ipv4: Bool, ipv6: Bool) -> IPWebsiteChecks {
        let sites = Latency.InternetSite.allCases.map(\.rawValue)
        return IPWebsiteChecks(ipv4: Dictionary(uniqueKeysWithValues: sites.map { ($0, ipv4) }),
                               ipv6: Dictionary(uniqueKeysWithValues: sites.map { ($0, ipv6) }))
    }

    private func calibrated() -> LiveHealthTracker {
        var health = LiveHealthTracker()
        for at in [0.0, 3, 6] { health.recordFallback(20, at: at) }
        return health
    }

    @Test func ipv6AndFallbackCannotMaskConfirmedIPv4Failure() throws {
        var health = calibrated()
        let v6Only = checks(ipv4: false, ipv6: true)
        health.recordIPWeb(v6Only, at: 7)
        #expect(health.report(now: 7)?.score == 100)
        health.recordFallback(20, at: 8)
        // Other completions cannot count one website round twice.
        #expect(health.report(now: 8)?.ipv4Unavailable == false)
        health.recordIPWeb(v6Only, at: 10)
        let report = try #require(health.report(now: 10))
        #expect(report.score == 33)
        #expect(report.ipv4Unavailable)
        #expect(report.ipv6Reachable)
        #expect(report.internetReachable) // Partial connectivity remains accurately represented.
        #expect(health.transportReport(now: 10)?.score == 100)
    }

    @Test func ipv6OnlyScalesDegradedHealthAndNeverRoundsToZero() throws {
        var health = LiveHealthTracker()
        for at in [0.0, 3, 6] { health.recordFallback(620, at: at) }
        #expect(health.transportReport(now: 10)?.score == 50)
        health.recordIPWeb(checks(ipv4: false, ipv6: true), at: 7)
        health.recordIPWeb(checks(ipv4: false, ipv6: true), at: 10)
        #expect(health.report(now: 10)?.score == 17)
        #expect(health.report(now: 10)?.score == 17) // Reading twice never applies the divisor twice.

        health.reset()
        for at in [0.0, 3, 6] { health.recordFallback(nil, at: at) }
        health.recordIPWeb(checks(ipv4: false, ipv6: true), at: 7)
        health.recordIPWeb(checks(ipv4: false, ipv6: true), at: 10)
        #expect(health.transportReport(now: 10)?.score == 0)
        #expect(health.report(now: 10)?.score == 1)
        var display = HealthDisplay()
        display.add(health.report(now: 10))
        _ = display.publish(now: 10)
        health.recordIPWeb(checks(ipv4: false, ipv6: false), at: 11)
        display.add(health.report(now: 11))
        let lostIPv6 = display.publish(now: 11)
        #expect(lostIPv6)
        #expect(display.shown?.score == 0)
        health.recordIPWeb(checks(ipv4: false, ipv6: true), at: 12)
        display.add(health.report(now: 12))
        let recoveredIPv6 = display.publish(now: 12)
        #expect(recoveredIPv6)
        #expect(display.shown?.score == 1)
    }

    @Test func ipv4AloneIsHealthyAndRecoversImmediately() throws {
        var health = calibrated(), display = HealthDisplay()
        display.add(health.report(now: 6))
        _ = display.publish(now: 6)
        health.recordIPWeb(checks(ipv4: false, ipv6: true), at: 7)
        health.recordIPWeb(checks(ipv4: false, ipv6: true), at: 8)
        display.add(health.report(now: 8))
        let outagePublished = display.publish(now: 8)
        #expect(outagePublished)
        #expect(display.shown?.score == 33)
        #expect(display.shown?.ipv4Unavailable == true)
        health.recordIPWeb(checks(ipv4: true, ipv6: false), at: 9)
        display.add(health.report(now: 9))
        let recoveryPublished = display.publish(now: 9)
        #expect(recoveryPublished)
        #expect(display.shown?.score == 100)
        #expect(display.shown?.ipv4Unavailable == false)
        #expect(display.shown?.ipv6Reachable == false)
        health.recordIPWeb(checks(ipv4: true, ipv6: false), at: 12)
        #expect(health.report(now: 12)?.score == 100)
        #expect(health.report(now: 12)?.websitesFailing == false)
    }

    @Test func calibrationAndFreshnessDoNotHideOrRetainCriticalFailure() {
        var health = LiveHealthTracker()
        health.recordIPWeb(checks(ipv4: false, ipv6: true), at: 0)
        health.recordIPWeb(checks(ipv4: false, ipv6: true), at: 3)
        #expect(health.report(now: 3)?.score == 33)
        #expect(health.report(now: 31) == nil) // First failure expired; no longer confirmed.
        health.reset()
        health.recordIPWeb(checks(ipv4: false, ipv6: true), at: 4)
        #expect(health.report(now: 4) == nil)
    }

    @Test func incompleteChecksAndSingleSiteFailuresDoNotConfirmAnOutage() {
        var health = calibrated()
        let failed = checks(ipv4: false, ipv6: true)
        health.recordIPWeb(failed, at: 7)
        var partial = failed
        partial.ipv4.removeValue(forKey: Latency.InternetSite.fastly.rawValue)
        #expect(partial.status(for: .ipv4) == .unknown)
        health.recordIPWeb(partial, at: 10)
        health.recordIPWeb(failed, at: 13)
        #expect(health.report(now: 13)?.score == 100)
        partial.ipv4[Latency.InternetSite.fastly.rawValue] = true
        #expect(partial.status(for: .ipv4) == .reachable)
        health.recordIPWeb(partial, at: 16)
        #expect(health.report(now: 16)?.score == 100)
    }

    @Test func anUnmeasuredRoundDoesNotClearAConfirmedIPv4Failure() {
        var health = LiveHealthTracker()
        let failed = checks(ipv4: false, ipv6: true)
        var unmeasured = failed
        unmeasured.ipv4.removeAll()
        #expect(unmeasured.status(for: .ipv4) == .unknown)
        health.recordIPWeb(failed, at: 0)
        health.recordIPWeb(failed, at: 3)
        #expect(health.report(now: 3)?.ipv4Unavailable == true)
        // curl could not run this round: that is no evidence IPv4 came back.
        health.recordIPWeb(unmeasured, at: 6)
        #expect(health.report(now: 6)?.ipv4Unavailable == true)
        #expect(health.report(now: 6)?.score == 33)
        health.recordIPWeb(failed, at: 9)
        #expect(health.report(now: 9)?.ipv4Unavailable == true)
        // Neither family could be measured: the IPv6 half of the verdict stands too.
        health.recordIPWeb(IPWebsiteChecks(), at: 12)
        #expect(health.report(now: 12)?.ipv4Unavailable == true)
        #expect(health.report(now: 12)?.ipv6Reachable == true)
        #expect(health.report(now: 12)?.score == 33)
        // The failures still expire, so unmeasured rounds alone cannot hold the warning.
        health.recordIPWeb(unmeasured, at: 34)
        #expect(health.report(now: 34)?.ipv4Unavailable != true)
        // A reachable round clears it at once.
        health.recordIPWeb(failed, at: 40)
        health.recordIPWeb(failed, at: 43)
        health.recordIPWeb(checks(ipv4: true, ipv6: true), at: 46)
        #expect(health.report(now: 46)?.ipv4Unavailable != true)
    }

    @Test func settlingSuppressesFailuresUntilConnectivityReturns() {
        var health = LiveHealthTracker()
        health.settle(at: 0)
        health.recordIPWeb(checks(ipv4: false, ipv6: false), at: 1)
        health.recordIPWeb(checks(ipv4: false, ipv6: false), at: 2)
        #expect(health.report(now: 2) == nil)
        health.recordIPWeb(checks(ipv4: false, ipv6: true), at: 3)
        health.recordIPWeb(checks(ipv4: false, ipv6: true), at: 4)
        #expect(health.report(now: 4)?.ipv4Unavailable == true)
    }

    @Test @MainActor func schedulerChecksBothFamiliesAndRetriesIPv4Failure() async throws {
        let failing = Locked(true)
        let transport = LiveProbes.Transport(ping: { _, _ in .reply(.init(ms: 20, hops: 12)) },
            website: { _, family in
                .init(outcome: family == .ipv4 && failing.value ? .failed("no route") : .ok, seconds: 0)
            }, portal: { .internet }, fallback: { _ in 20 })
        let probes = LiveProbes(transport: transport)
        var rounds: [IPWebsiteChecks] = []
        probes.receive = { _, event in
            if case .websites(let checks) = event { rounds.append(checks) }
        }
        let identity = Identity(iface: nil, type: NetType.offline, network: nil, bssid: nil,
                                router: nil, rssi: nil, noise: nil, txRate: nil, channel: nil)
        let now = HealthTracker.now()
        probes.poll(identity: identity, epoch: 1, paused: false, now: now)
        for _ in 0..<100 {
            if rounds.count == 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(rounds.count == 1)
        #expect(rounds.first?.status(for: .ipv4) == .unreachable)
        #expect(rounds.first?.status(for: .ipv6) == .reachable)
        failing.set(false)
        probes.poll(identity: identity, epoch: 1, paused: false, now: now + 3)
        for _ in 0..<100 {
            if rounds.count == 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(rounds.count == 2) // IPv6 success must not switch to the healthy 15-second cadence.
        #expect(rounds.last?.status(for: .ipv4) == .reachable)
    }

    @Test func switchingWANFamilyExcludesIPv4LossAndLatencyButKeepsPenalty() throws {
        var health = LiveHealthTracker()
        for at in [0.0, 3, 6] {
            health.recordTarget(slot: 0, verdict: .wan(620), started: at, at: at)
            health.recordTarget(slot: 1, verdict: .noReply, started: at, at: at)
        }
        health.recordFallback(900, at: 6)
        health.recordIPWeb(checks(ipv4: false, ipv6: true), at: 7)
        health.recordIPWeb(checks(ipv4: false, ipv6: true), at: 10)
        health.selectWANFamily(.ipv6)
        #expect(health.latencyReadings(now: 10).isEmpty)
        #expect(health.transportReport(now: 10) == nil)
        #expect(health.report(now: 10)?.ipv4Unavailable == true)
        for at in [11.0, 14, 17] {
            health.recordTarget(slot: 0, verdict: .wan(20), started: at, at: at)
            health.recordTarget(slot: 3, verdict: .wan(30), started: at, at: at)
        }
        let report = try #require(health.report(now: 17))
        #expect(report.score == 33)
        #expect(report.loss == 0)
        #expect(report.jitterMs == 0)
        #expect(report.latencyMs == 20)
        #expect(report.latencySources == [.icmp])
        #expect(health.latencyReadings(now: 17) == [20, 20, 20])
        health.selectWANFamily(.ipv4)
        health.recordIPWeb(checks(ipv4: true, ipv6: true), at: 18)
        for at in [19.0, 22, 25] { health.recordTarget(slot: 0, verdict: .wan(40), started: at, at: at) }
        #expect(health.report(now: 25)?.score == 100)
        #expect(health.latencyReadings(now: 25) == [40, 40, 40])
    }

    @Test @MainActor func IPv6StartsWhileIPv4IsBlockedAndOldRepliesCannotSurviveSwitchingBack() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { for _ in Latency.icmpTargets { gate.signal() } }
        let recovered = Locked(false), blocked = Locked(0), finished = Locked(0)
        let transport = LiveProbes.Transport(ping: { host, _ in
            if !host.contains(":"), !recovered.value {
                blocked.mutate { $0 += 1 }
                _ = gate.wait(timeout: .now() + 5)
                finished.mutate { $0 += 1 }
                return .reply(.init(ms: 999, hops: 12))
            }
            return .reply(.init(ms: host.contains(":") ? 20 : 40, hops: 12))
        }, website: { _, family in
            .init(outcome: family == .ipv4 && !recovered.value ? .failed("no route") : .ok, seconds: 0)
        }, portal: { .internet }, fallback: { _ in nil })
        let probes = LiveProbes(transport: transport)
        var families: [IPVersion] = [], replies: [(IPVersion, Double)] = []
        probes.receive = { _, event in
            if case .wanFamily(let family) = event { families.append(family) }
            if case .wan(let family, _, _, .reply(let reply), _) = event { replies.append((family, reply.ms)) }
        }
        let identity = Identity(iface: nil, type: NetType.offline, network: nil, bssid: nil,
                                router: nil, rssi: nil, noise: nil, txRate: nil, channel: nil)
        let now = HealthTracker.now()
        probes.poll(identity: identity, epoch: 1, paused: false, now: now)
        for _ in 0..<100 {
            if families == [.ipv6] && blocked.value == Latency.icmpTargets.count { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(families == [.ipv6])
        #expect(blocked.value == Latency.icmpTargets.count)
        probes.poll(identity: identity, epoch: 1, paused: false, now: now + 1)
        for _ in 0..<100 {
            if replies.count == Latency.icmp6Targets.count { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(replies.count == Latency.icmp6Targets.count)
        #expect(replies.allSatisfy { $0.0 == .ipv6 && $0.1 == 20 })
        recovered.set(true)
        probes.poll(identity: identity, epoch: 1, paused: false, now: now + 3)
        for _ in 0..<100 {
            if families == [.ipv6, .ipv4] { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(families == [.ipv6, .ipv4])
        for _ in Latency.icmpTargets { gate.signal() }
        for _ in 0..<100 {
            if finished.value == Latency.icmpTargets.count { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(!replies.contains { $0.1 == 999 })
        probes.poll(identity: identity, epoch: 1, paused: false, now: now + 4)
        for _ in 0..<100 {
            if replies.contains(where: { $0.0 == .ipv4 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(replies.contains { $0.0 == .ipv4 && $0.1 == 40 })
        #expect(!replies.contains { $0.1 == 999 })
    }

    @Test func combinedResultsOnlyBlameASiteAWorkingFamilyFailedToReach() {
        let sites = Latency.InternetSite.allCases.map(\.rawValue)
        // IPv4 needed only its first site; IPv6 has no access and failed both.
        var v4Only = IPWebsiteChecks(ipv4: [sites[0]: true], ipv6: [sites[0]: false, sites[1]: false])
        #expect(v4Only.combined == [sites[0]: true])
        // The working family tried the other site too, and it failed there.
        v4Only.ipv4[sites[1]] = false
        #expect(v4Only.combined == [sites[0]: true, sites[1]: false])
        // With no working family every failure stands.
        let down = IPWebsiteChecks(ipv4: [sites[0]: false, sites[1]: false], ipv6: [sites[0]: false])
        #expect(down.combined == [sites[0]: false, sites[1]: false])
        #expect(IPWebsiteChecks(ipv4: [sites[0]: true], ipv6: [sites[1]: true]).combined == [sites[0]: true, sites[1]: true])
    }

    private func unresolvedChecks() -> IPWebsiteChecks {
        var checks = IPWebsiteChecks()
        for site in Latency.InternetSite.allCases {
            checks.record(.init(outcome: .failed("curl 6 unresolved"), seconds: 0, unresolved: true), site: site, family: .ipv4)
            checks.record(.init(outcome: .failed(Latency.noIPv6RouteReason), seconds: 0), site: site, family: .ipv6)
        }
        return checks
    }

    @Test func aRoundIsADNSFailureOnlyWhenEveryIPv4SiteFailedToResolve() {
        var checks = unresolvedChecks()
        #expect(checks.dnsFailed)
        // IPv6 reaching a site means names resolve.
        var reached = checks
        reached.record(.init(outcome: .ok, seconds: 0.1), site: .google, family: .ipv6)
        #expect(!reached.dnsFailed)
        // One site resolved and then failed to connect: not a DNS fault.
        checks.record(.init(outcome: .failed("curl 7"), seconds: 0), site: .google, family: .ipv4)
        #expect(!checks.dnsFailed)
        // IPv6 resolved a name and then failed to connect: names resolve.
        var connected = unresolvedChecks()
        connected.record(.init(outcome: .failed("curl 7"), seconds: 0), site: .google, family: .ipv6)
        #expect(!connected.dnsFailed)
        // A site that was never measured leaves the round undecided.
        var partial = IPWebsiteChecks()
        partial.record(.init(outcome: .failed("curl 6 unresolved"), seconds: 0, unresolved: true), site: .google, family: .ipv4)
        #expect(!partial.dnsFailed)
    }

    @Test func unresolvedNamesAreDiagnosedAsDNSOnlyWhilePingsAnswer() throws {
        var health = LiveHealthTracker()
        health.recordTarget(slot: 0, verdict: .wan(20), started: 1, at: 1)
        health.recordIPWeb(unresolvedChecks(), at: 2)
        #expect(health.report(now: 2)?.ipv4Unavailable != true)
        // The reply so far predates the failed lookups.
        #expect(health.report(now: 2)?.dnsFailing != true)
        health.recordTarget(slot: 0, verdict: .wan(20), started: 4, at: 4)
        health.recordIPWeb(unresolvedChecks(), at: 5)
        let report = try #require(health.report(now: 5))
        #expect(report.dnsFailing)
        #expect(report.ipv4Unavailable)
        #expect(report.score == 0)

        // With nothing answering, unresolved names are a symptom of the outage.
        var offline = LiveHealthTracker()
        offline.recordIPWeb(unresolvedChecks(), at: 2)
        offline.recordIPWeb(unresolvedChecks(), at: 5)
        let down = try #require(offline.report(now: 5))
        #expect(!down.dnsFailing)
        #expect(down.ipv4Unavailable)

        // An outage starting: the last reply came just before it, and the pings sent since are
        // still waiting out their timeout, so no loss has been recorded yet.
        var dying = LiveHealthTracker()
        dying.recordTarget(slot: 0, verdict: .wan(20), started: 1, at: 1)
        dying.recordIPWeb(unresolvedChecks(), at: 2)
        dying.recordIPWeb(unresolvedChecks(), at: 6)
        let dead = try #require(dying.report(now: 6))
        #expect(dead.ipv4Unavailable)
        #expect(!dead.dnsFailing)

        // The flag reaches what the menu shows, and leaves it.
        var display = HealthDisplay()
        display.add(report)
        let shownDNS = display.publish(now: 5)
        #expect(shownDNS)
        #expect(display.shown?.dnsFailing == true)
        display.add(dead)
        let shownOutage = display.publish(now: 6)
        #expect(shownOutage)
        #expect(display.shown?.dnsFailing == false)

        // IPv6 reaches a site in a round where the IPv4 check could not run: names resolve.
        var recovering = health
        var v6Only = IPWebsiteChecks()
        v6Only.record(.init(outcome: .ok, seconds: 0.1), site: .google, family: .ipv6)
        recovering.recordTarget(slot: 0, verdict: .wan(20), started: 7, at: 7)
        recovering.recordIPWeb(v6Only, at: 8)
        let partly = try #require(recovering.report(now: 8))
        #expect(partly.ipv4Unavailable)
        #expect(partly.ipv6Reachable)
        #expect(!partly.dnsFailing)

        // During a DNS fault the upstream dies too: once replies stop, so does the diagnosis.
        health.recordIPWeb(unresolvedChecks(), at: 16)
        #expect(health.report(now: 16)?.dnsFailing == false)

        // Names resolving again clears it.
        health.recordIPWeb(checks(ipv4: true, ipv6: false), at: 18)
        #expect(health.report(now: 18)?.dnsFailing != true)
    }

    @Test func ipv6WebsiteCheckWithoutARouteFailsWithoutRunningCurl() {
        var checks = IPWebsiteChecks()
        for site in Latency.InternetSite.allCases {
            let check = Latency.checkInternet(site, family: .ipv6, hasIPv6Route: { false })
            guard case .failed(let why) = check.outcome else { Issue.record("Expected a failure: \(check.summary)"); return }
            #expect(why == Latency.noIPv6RouteReason)
            #expect(check.seconds == 0)
            #expect(!check.unresolved)
            checks.record(check, site: site, family: .ipv6)
        }
        // The family is unreachable exactly as when curl failed to connect.
        #expect(checks.status(for: .ipv6) == .unreachable)
        #expect(checks.status(for: .ipv4) == .unknown)
        // The lookup itself sends nothing and must answer on any network.
        _ = Latency.hasIPv6Route()
    }

    @Test func pingTargetsUseOneAddressPerOperator() {
        #expect(Latency.icmpTargets.count == 5)
        #expect(Set(Latency.icmpTargets).count == 5)
        #expect(!Latency.icmpTargets.contains("1.0.0.1"))
        #expect(!Latency.icmp6Targets.contains("2606:4700:4700::1001"))
        // The IPv6 HTTPS fallback still needs Cloudflare hosts, whatever the ping targets are.
        #expect(Latency.trace6Hosts.allSatisfy { $0.hasPrefix("2606:4700:4700:") })
    }

    @Test @MainActor func ipv6HTTPSFallbackDoesNotWaitForOldIPv4Fallback() async throws {
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let v6Ready = Locked(false), calls = Locked<[IPVersion]>([])
        let transport = LiveProbes.Transport(ping: { _, _ in .lost }, website: { _, family in
            .init(outcome: family == .ipv6 && v6Ready.value ? .ok : .failed("no route"), seconds: 0)
        }, portal: { .unknown }, fallback: { family in
            calls.mutate { $0.append(family) }
            if family == .ipv4 { _ = gate.wait(timeout: .now() + 5) }
            return family == .ipv6 ? 25 : 999
        })
        let probes = LiveProbes(transport: transport)
        var selected = IPVersion.ipv4
        var results: [(IPVersion, Double?)] = []
        var websiteRounds = 0
        probes.receive = { _, event in
            if case .wanFamily(let family) = event { selected = family }
            if case .fallback(let family, let ms) = event { results.append((family, ms)) }
            if case .websites = event { websiteRounds += 1 }
        }
        let identity = Identity(iface: nil, type: NetType.offline, network: nil, bssid: nil,
                                router: nil, rssi: nil, noise: nil, txRate: nil, channel: nil)
        let now = HealthTracker.now()
        probes.poll(identity: identity, epoch: 1, paused: false, now: now)
        // The next round can only start once this one has reported, however busy the machine is.
        for _ in 0..<200 where websiteRounds == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(websiteRounds == 1)
        v6Ready.set(true)
        probes.poll(identity: identity, epoch: 1, paused: false, now: now + 9)
        for _ in 0..<100 {
            if selected == .ipv6 && calls.value.contains(.ipv4) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(selected == .ipv6)
        #expect(calls.value.contains(.ipv4))
        probes.poll(identity: identity, epoch: 1, paused: false, now: now + 18)
        for _ in 0..<100 {
            if !results.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(calls.value.contains(.ipv6))
        #expect(results.count == 1)
        #expect(results.first?.0 == .ipv6)
        #expect(results.first?.1 == 25)
    }

    @Test func IPv6HopLimitRejectsMissingTruncatedAndLocalReplies() {
        var header = cmsghdr()
        header.cmsg_len = socklen_t(MemoryLayout<cmsghdr>.size + MemoryLayout<Int32>.size)
        header.cmsg_level = IPPROTO_IPV6
        header.cmsg_type = IPv6Pinger.hopLimitControlType
        var hopLimit: Int32 = 52
        var control = withUnsafeBytes(of: &header) { Array($0) }
        control += withUnsafeBytes(of: &hopLimit) { Array($0) }
        let ttl = IPv6Pinger.hopLimit(control: control, length: control.count)
        #expect(ttl == 52)
        #expect(Latency.judge(.init(ms: 20, hops: ttl.map(Latency.inferredHops)), gatewayMs: nil) == .wan(20))
        #expect(IPv6Pinger.hopLimit(control: control, length: control.count - 1) == nil)
        #expect(IPv6Pinger.hopLimit(control: [], length: 0) == nil)
        #expect(Latency.judge(.init(ms: 20, hops: nil), gatewayMs: nil) == .noReply)
        #expect(Latency.judge(.init(ms: 20, hops: Latency.inferredHops(ttl: 63)), gatewayMs: nil) == .onPath)
    }

    @Test func IPv6LoopbackProvidesReceivedHopLimit() {
        let result = IPv6Pinger.ping("::1", timeoutMs: 1000)
        guard case .reply(let reply) = result else { Issue.record("Expected IPv6 loopback reply: \(result)"); return }
        #expect(reply.hops == 0)
        #expect(reply.ms < 100)
    }

    @Test @MainActor func menuExplainsPartialConnectivityAndClearsOnRecovery() {
        let app = AppDelegate()
        var report = HealthReport(score: 33, loss: 0, jitterMs: nil, latencyMs: nil,
                                  ipv4Unavailable: true, ipv6Reachable: true)
        let warning = app.healthMenuReadout(report)
        #expect(warning.score == 33)
        #expect(warning.detail == "⚠ IPv4 unavailable; IPv6 is working")
        #expect(warning.title.contains("IPv4 unavailable"))
        report.ipv6Reachable = false
        report.score = 0
        #expect(app.healthMenuReadout(report).detail == "⚠ IPv4 internet unavailable")
        report.ipv4Unavailable = false
        report.score = 100
        #expect(!app.healthMenuReadout(report).detail.contains("⚠"))
        report.websitesFailing = true
        #expect(app.healthMenuReadout(report).detail.contains("websites failed"))
        report.dnsFailing = true
        #expect(app.healthMenuReadout(report).detail.contains("DNS lookups failed"))
        let dns = HealthReport(score: 0, loss: 0, jitterMs: nil, latencyMs: nil, internetReachable: false,
                               ipv4Unavailable: true, dnsFailing: true)
        #expect(app.healthMenuReadout(dns).detail == "⚠ DNS not resolving names; pings still answer")
    }
}
