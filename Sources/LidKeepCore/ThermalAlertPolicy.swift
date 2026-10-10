import Foundation

/// Decides when a lid-closed fair thermal state deserves one notification. Never changes power.
public struct ThermalAlertPolicy {
    public enum Observation: Equatable { case elevated, cleared, unknown }
    public static let sustainSeconds: Double = 300
    public static let minimumIntervalSeconds: Double = 1800
    public static let retrySeconds: Double = 300
    public static let maximumGapSeconds: Double = 30

    private var elevatedSince: Double?   // start of the current continuous confirmed-elevated run
    private var lastObservation: Double?
    private var episodeActive = false     // an episode began and has not been confirmed over
    private var episodeAlerted = false    // the system accepted a notification for this episode
    private var pending = false           // a post is in flight
    private var lastFailure: Double?
    private var lastAlert: Double?        // last accepted notification

    public init() {}

    /// Map raw readings to an observation. Only confirmed facts may clear an episode.
    public static func classify(lidClosed: Bool?, statusFresh: Bool,
                                keepingAwake: Bool, thermal: ThermalLevel) -> Observation {
        if lidClosed == false { return .cleared }
        if statusFresh && !keepingAwake { return .cleared }
        if statusFresh && thermal == .nominal { return .cleared }
        if lidClosed == true && statusFresh && keepingAwake && thermal == .fair { return .elevated }
        // Unknown lid, stale status, unknown thermal, or a transient serious reading before protection.
        return .unknown
    }

    /// Returns the sustained seconds when a notification should be submitted now, otherwise nil.
    public mutating func observe(now: Double, _ observation: Observation) -> Double? {
        let gap = lastObservation.map { now < $0 || now - $0 > Self.maximumGapSeconds } ?? false
        lastObservation = now
        switch observation {
        case .cleared:
            episodeActive = false
            episodeAlerted = false
            elevatedSince = nil
            lastFailure = nil
            return nil
        case .unknown:
            // Restart the sustain timer only; the episode and its alert record survive.
            elevatedSince = nil
            return nil
        case .elevated:
            episodeActive = true
            if elevatedSince == nil || gap { elevatedSince = now }
            let duration = now - elevatedSince!
            if episodeAlerted || pending || duration < Self.sustainSeconds { return nil }
            if let lastAlert, now - lastAlert < Self.minimumIntervalSeconds { return nil }
            if let lastFailure, now - lastFailure < Self.retrySeconds { return nil }
            pending = true
            return duration
        }
    }

    public mutating func delivered(at now: Double) {
        pending = false
        lastAlert = now
        lastFailure = nil
        if episodeActive { episodeAlerted = true }
    }

    public mutating func failed(at now: Double) {
        pending = false
        lastFailure = now
    }

    /// Setting turned off: forget the episode; keep lastAlert so the 30-minute interval still holds.
    public mutating func reset() {
        elevatedSince = nil
        lastObservation = nil
        episodeActive = false
        episodeAlerted = false
        lastFailure = nil
    }
}
