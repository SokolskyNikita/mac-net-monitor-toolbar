import Foundation

/// Compiled product defaults. Edit here and rebuild; user preferences remain in UserDefaults.
/// Value types allow tests to override one section without changing process-wide settings.
/// Durations are seconds unless a name ends in Ms; sizes are bytes.
enum Configuration {
    /// Default probe scheduling, freshness, sampling and network-detection policy.
    static let monitoring = MonitoringConfig()
    /// Default scoring calibration, history window and display smoothing.
    static let health = HealthConfig()
    /// Default log cadence, retention and diagnostic rate limits.
    static let logging = LoggingConfig()
    /// Default watchdog, helper-process and cleanup limits.
    static let reliability = ReliabilityConfig()
}

// MARK: - Monitoring

struct MonitoringConfig {
    /// Minimum spacing between starts of router, WAN and active fallback probes.
    var probeInterval: TimeInterval = 3
    /// Maximum age of an RTT reading eligible for the menu-bar latency.
    var latencyStaleAfter: TimeInterval = 60
    /// How often to refresh the interface, network name and router identity.
    var identityInterval: TimeInterval = 15
    /// Number of recent RTT readings used for the menu-bar median.
    var displayLatencyReadings = 5
    /// WAN ping reply deadline in milliseconds; allows slow satellite replies.
    var icmpTimeoutMs = 8000
    /// Reply deadline in milliseconds for each local-router protocol attempt.
    var localTimeoutMs = 1000
    /// Deadline for the Apple captive-portal HTTP check.
    var captiveTimeout: TimeInterval = 4
    /// Deadline for the HTTPS trace used when WAN ping is unavailable.
    var httpTimeout: TimeInterval = 15
    /// Deadline for each ordinary HTTPS website reachability check.
    var websiteTimeout: TimeInterval = 8
    /// Extra time beyond the WAN ping deadline for helpers to finish in a batch cycle.
    var cycleCleanupAllowance: TimeInterval = 6
    /// Outer deadline for the parallel portion of a batch probe cycle.
    var cycleTimeout: TimeInterval { Double(icmpTimeoutMs) / 1000 + cycleCleanupAllowance }
    /// Wait one WAN ping deadline before starting HTTPS fallback on a new network.
    var initialFallbackDelay: TimeInterval { Double(icmpTimeoutMs) / 1000 }
    /// Echoes this many hops away or closer are rejected as local-path replies.
    var maxLocalHops = 3
    /// Extra RTT above the gateway, in milliseconds, still considered local at gatewayEchoMaxHops.
    var gatewayEchoToleranceMs = 15.0
    /// Maximum hop distance at which the gateway-relative RTT rejection applies.
    var gatewayEchoMaxHops = 6
    /// Minimum process deadline for subprocess ping, even with a short reply timeout.
    var pingHelperMinTimeout: TimeInterval = 3
    /// Healthy probe cycles between website and captive checks in the batch scheduler.
    var websiteCheckEvery = 5
    /// Spacing of website and captive checks while live monitoring is healthy.
    var healthyWebsiteInterval: TimeInterval { probeInterval * Double(websiteCheckEvery) }
    /// How long a WAN failure or captive portal keeps website checks at the fast cadence.
    var troubleProbeDuration: TimeInterval = 15
    /// How long a successful WAN ping takes precedence over fallback and outage evidence.
    var wanFreshFor: TimeInterval = 10
    /// Maximum age of gateway RTT used to identify local-path WAN echo replies.
    var gatewayFreshFor: TimeInterval = 10
    /// Maximum age of website and captive-portal evidence used to confirm an outage.
    var websiteFreshFor: TimeInterval = 30
    /// Maximum age of a failed HTTPS fallback that can corroborate an outage.
    var fallbackFailureFreshFor: TimeInterval = 20
    /// Consecutive failures of a previously working router protocol before trying alternatives.
    var localFailureLimit = 3
    /// Minimum spacing between attempts to discover another working router protocol.
    var localDiscoveryInterval: TimeInterval = 30
    /// Background preferred-protocol retry delays; the last delay repeats indefinitely.
    var localRetryDelays: [TimeInterval] = [30, 60, 120, 300]
    /// Variation in background retry deadlines to avoid synchronized probing.
    var localRetryJitter = 0.20
    /// Spacing between confirmation probes after a preferred protocol first answers.
    var localConfirmationInterval: TimeInterval = 1
    /// Successful trial probes required before promotion, including the first reply.
    var localConfirmationCount = 3
    /// A promoted protocol rolls back after two consecutive failures during this period.
    var localProbationInterval: TimeInterval = 15
    var localProbationFailureLimit = 2
    /// How long a latency, jitter, loss or web-access warning stays visible.
    var recentTroubleDuration: TimeInterval = 10
    /// Minimum fractional health penalty that triggers a latency or jitter warning (0.05 = 5%).
    var recentTroublePenalty = 0.05
    /// Rolling period over which completed disconnect/reconnect events are counted.
    var reconnectWindow: TimeInterval = 300
    /// Minimum reconnect count in that window before showing the menu warning.
    var reconnectWarningCount = 3

    /// Spacing of physical-interface byte-counter reads; also drives the main monitoring tick.
    var bandwidthSampleInterval: TimeInterval = 1
    /// How often accumulated throughput samples are averaged into the display.
    var bandwidthDisplayInterval: TimeInterval = 5
    /// Longer gaps rebase counters instead of treating the gap as live throughput.
    var bandwidthMaxSampleInterval: TimeInterval = 5
    /// Shorter samples contribute to averages but cannot establish throughput peaks.
    var bandwidthMinPeakInterval: TimeInterval = 0.75
    /// Interval between nettop snapshots used to rank apps and count packet traffic.
    var appSampleInterval: TimeInterval = 10
    /// Extra time allowed for nettop startup and completion beyond its sampling interval.
    var appSampleAllowance: TimeInterval = 5
    /// Maximum runtime of one nettop collection command.
    var appCommandTimeout: TimeInterval { appSampleInterval + appSampleAllowance }
    /// Longest elapsed collection interval accepted as a valid app-traffic sample.
    var appMaxSampleSeconds: TimeInterval { appCommandTimeout }
    /// Maximum age for presenting app traffic and connection counts as current.
    var appFreshFor: TimeInterval { appCommandTimeout }
    /// Maximum age of the last app ranking retained through sampler failures or restarts.
    var appRetainFor: TimeInterval = 60
    /// Failed samples before an app ranking with no previous data becomes unavailable.
    var appInitialFailureLimit = 3
    /// Maximum delay between retries after nettop collection failures.
    var appRetryMaxDelay: TimeInterval = 30
    /// Caps the exponent in the retry delay of 2^(consecutive failures - 1) seconds.
    var appRetryMaxExponent = 5

    /// Maximum cache age for interface-to-hardware-port names; unknown interfaces refresh sooner.
    var portsCacheLifetime: TimeInterval = 300
    /// Process deadline for reading an interface summary with ipconfig.
    var ipconfigTimeout: TimeInterval = 5
}

// MARK: - Health scoring

struct HealthConfig {
    /// Maximum sample age included in rolling health calculations.
    var window: TimeInterval = 60
    /// Minimum measured cycles before showing health; confirmed outages bypass calibration.
    var minCycles = 3
    /// Identifier written to stats logs; change it when scoring calibration changes.
    var model = "delay_budget_v2"
    /// Divide transport health by this when IPv4 is unavailable but IPv6 websites work.
    var ipv6OnlyScoreDivisor = 3.0
    /// Sample weight halves for each interval of this age within the health window.
    var recencyHalfLife: TimeInterval = 15
    /// Fixed processing delay added to RTT/2 and jitter in the delay budget, in milliseconds.
    var processingAllowanceMs = 40.0
    /// Delay-budget allowance in milliseconds before latency and jitter reduce health.
    var freeDelayMs = 150.0
    /// Excess delay in milliseconds that halves health through the squared delay penalty.
    var delayHalfScaleMs = 200.0
    /// Loss fraction tolerated without penalty (0.01 = 1%).
    var freeLoss = 0.01
    /// Additional loss fraction above freeLoss that halves health (0.04 = four percentage points).
    var lossHalfScale = 0.04
    /// Minimum loss-rate gap from other targets before considering a target an ICMP-filtering outlier.
    var lossOutlierMargin = 0.10
    /// Binomial tail probability must fall below this to exclude a suspected loss outlier.
    var lossOutlierPValue = 0.01
    /// Minimum interval between publishing averaged health reports; outages update immediately.
    var displayInterval: TimeInterval = 10
    /// Maximum time to ignore failures after wake/network change; any success ends settling early.
    var settleLimit: TimeInterval = 30
}

// MARK: - Speed tests

struct SpeedTestConfig {
    /// Normal combined download/upload payload allowance; protocol overhead is additional.
    var budgetBytes: Int
    /// Hard total payload ceiling after any fast-link budget extensions.
    var maxBudgetBytes: Int
    /// Measured Mbps required to extend an exhausted phase budget toward its ceiling.
    var fastLinkMbps = 150.0
    /// Maximum fraction of the total payload budget allocated to download.
    var maxDownloadShare = 0.625
    /// Concurrent transfer connections started per direction, capped by maxStreams.
    var initialStreams = 4
    /// Maximum concurrent transfer connections per direction.
    var maxStreams = 4
    /// Measured Mbps above which a phase adds connections up to maxStreams.
    var parallelAboveMbps = 5.0
    /// Baseline ramp-up time excluded from throughput; raised to four idle RTTs if needed.
    var warmup: TimeInterval = 1
    /// Maximum RTT-adjusted ramp-up exclusion before applying the byte-share limit.
    var maxWarmup: TimeInterval = 3
    /// Maximum fraction of phase bytes that warmup may exclude (0.5 preserves at least half).
    var latestWarmupShare = 0.5
    /// Minimum post-warmup measurement duration before a stable rate can end the phase.
    var minSteady: TimeInterval = 2
    /// Maximum transfer-phase duration measured from its first credited byte.
    var maxPhase: TimeInterval = 12
    /// Maximum wait for the first credited byte, or gap between credited bytes, before aborting.
    var stallTimeout: TimeInterval = 8
    /// Relative rate variation allowed for stability; also flags budget-limited rate growth.
    var stabilityTolerance = 0.10
    /// Baseline target duration of each download request, increased for high RTT.
    var requestTarget: TimeInterval = 0.75
    /// Baseline target duration of each upload request, increased for high RTT.
    var uploadRequestTarget: TimeInterval = 0.4
    /// Upper limit on the RTT-adjusted target duration used to size requests.
    var maxRequestTarget: TimeInterval = 4
    /// First payload request size per connection, before adaptive growth.
    var initialRequest = 65_536
    /// Minimum payload reservation; a smaller remaining budget cannot start another request.
    var minRequest = 16_384
    /// Maximum payload size of any single download or upload request.
    var maxRequest = 8_000_000
    /// Deadline for one payload transfer request.
    var requestTimeout: TimeInterval = 15
    /// Pause between consecutive latency probes while a transfer is running.
    var latencyProbeInterval: TimeInterval = 0.4
    /// Number of idle latency attempts after the discarded connection-warmup probe.
    var idleLatencySamples = 5
    /// Deadline for a latency probe; the initial connection-warmup probe gets twice this.
    var latencyTimeout: TimeInterval = 3
    /// How often the phase checks cancellation, progress, stalls and stopping conditions.
    var tick: TimeInterval = 0.1

    /// Delay before another test is allowed after a fully successful result.
    var cooldown: TimeInterval = 60
    /// Delay before retrying a failed or partial test; cancellation has no cooldown.
    var failureCooldown: TimeInterval = 15
    /// How long the completed test result remains visible in the menu.
    var resultLifetime: TimeInterval = 300

    /// Normal total payload allowance for the standard preset.
    static let standardBudget = 32_000_000
    /// Maximum total payload allowance for the standard preset on fast links.
    static let fastLinkBudget = 64_000_000
    /// Fixed total payload allowance on Low Data Mode or metered paths.
    static let lowDataBudget = 8_000_000
    /// Normal-network preset, with budget expansion allowed on sufficiently fast links.
    static let standard = SpeedTestConfig(budgetBytes: standardBudget, maxBudgetBytes: fastLinkBudget)
    /// Metered-network preset, with equal normal and maximum budgets to prevent expansion.
    static let lowData = SpeedTestConfig(budgetBytes: lowDataBudget, maxBudgetBytes: lowDataBudget)

    /// Normal download allowance derived from the total budget and download share.
    var downloadBudget: Int { Int(Double(budgetBytes) * maxDownloadShare) }
    /// Download ceiling after a fast-link extension, preserving the same allocation share.
    var maxDownloadBudget: Int { Int(Double(maxBudgetBytes) * maxDownloadShare) }

    /// Remaining total allowance, preserving the normal upload share within the hard ceiling.
    func uploadBudget(downloadUsed: Int) -> Int {
        min(maxBudgetBytes - downloadUsed, max(budgetBytes - downloadBudget, budgetBytes - downloadUsed))
    }
}

// MARK: - Logging

struct LoggingConfig {
    /// How often completed monitoring aggregates are flushed to the stats log.
    var statsInterval: TimeInterval = 60
    /// Stats-file byte limit that triggers compaction before an append would exceed it.
    var statsMaxBytes = 100_000_000
    /// Fraction of the byte budget to trim, expressed as 1/divisor and rounded down (10 means 10%).
    var statsTrimDivisor = 10
    /// Target byte size after compaction, using integer rounding for the supplied file limit.
    func retainedStatsBytes(maxBytes: Int) -> Int { maxBytes - maxBytes / statsTrimDivisor }
    /// Compaction target derived from the configured stats-file limit.
    var statsRetainedBytes: Int { retainedStatsBytes(maxBytes: statsMaxBytes) }
    /// Maximum WAN and router latency readings retained per stats window; packet counts remain complete.
    var maxProbeReadings = 120
    /// Size at which the active diagnostic log rotates, in bytes.
    var diagnosticMaxFileBytes = 10_000_000
    /// Number of rotated diagnostic files retained in addition to the active log.
    var diagnosticArchives = 2
    /// Minimum spacing between diagnostic messages sharing the same throttle key.
    var diagnosticThrottleInterval: TimeInterval = 60
    /// Minimum delay before retrying a failed diagnostic-log open.
    var diagnosticOpenRetryInterval: TimeInterval = 5
    /// Spacing of resource-usage and monitoring-progress summaries in the diagnostic log.
    var heartbeatInterval: TimeInterval = 300
    /// Warn when no probe result arrives for this long while awake.
    var probeQuietWarning: TimeInterval = 120
}

// MARK: - Reliability

struct ReliabilityConfig {
    /// Watchdog descriptor threshold, additionally capped at half the process soft limit.
    var maxFileDescriptors = 1000
    /// Watchdog relaunch threshold for this process's thread count.
    var maxThreads = 300
    /// Watchdog relaunch threshold for this process's physical memory footprint.
    var maxFootprintBytes: UInt64 = 1_500_000_000
    /// Main-thread nonresponse duration beyond which the watchdog considers the app hung.
    var mainHang: TimeInterval = 120
    /// Minimum age of this app process before watchdog relaunch is allowed, preventing restart loops.
    var minUptime: TimeInterval = 30 * 60
    /// Spacing of background resource and main-thread responsiveness checks.
    var watchdogInterval: TimeInterval = 60
    /// Scheduling tolerance allowed for the watchdog timer to reduce wakeups.
    var watchdogLeeway: TimeInterval = 5
    /// Process deadline for opening a replacement app instance during watchdog recovery.
    var relaunchTimeout: TimeInterval = 15
    /// Time allowed for normal app termination before forcing exit after a successful relaunch.
    var restartExitGrace: TimeInterval = 10
    /// Extra time beyond a probe's own deadline for its helper or callback to complete.
    var probeCompletionAllowance: TimeInterval = 2
    /// Default runtime limit for helper commands without a more specific deadline.
    var helperTimeout: TimeInterval = 10
    /// Wait after SIGTERM before sending SIGKILL to an unresponsive helper.
    var helperTerminateGrace: TimeInterval = 1
    /// Wait for a killed helper to stop after SIGKILL.
    var helperReapGrace: TimeInterval = 1
    /// Wait for helper stdout/stderr pipes to reach EOF after the helper exits.
    var helperDrainTimeout: TimeInterval = 2
    /// Maximum age since helper launch for attributing its traffic to NetMenu in app rankings.
    var helperHistoryLifetime: TimeInterval = 600
    /// Minimum age of NetMenu-prefixed temporary files eligible for startup cleanup.
    var staleTempFileAge: TimeInterval = 600
}
