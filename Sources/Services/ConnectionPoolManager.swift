// ConnectionPoolManager.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation
@preconcurrency import MultipeerConnectivity
import Combine
#if canImport(UIKit)
import UIKit
#endif

/// Helper to wrap non-Sendable closures for use in async contexts
/// Use with caution - ensures the value is only accessed from expected contexts
private struct SendableBox<T: Sendable>: Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}


/// Manages peer-to-peer connections using MultipeerConnectivity framework
@MainActor
public final class ConnectionPoolManager: NSObject, ObservableObject {

    // MARK: - Singleton

    /// Shared instance for app-wide connection persistence
    /// This ensures the connection survives window close/reopen cycles
    public static let shared = ConnectionPoolManager()

    // MARK: - Constants

    /// Service type for Bonjour discovery (must be 1-15 chars, lowercase, hyphens OK)
    private static let serviceType = "stealthos-pool"

    /// Maximum peers supported by MultipeerConnectivity (including host)
    public static let maxPeers = 8

    /// Invitation timeout in seconds
    private static let invitationTimeout: TimeInterval = 30

    // MARK: - Published Properties

    @Published public private(set) var poolState: PoolState = .idle
    @Published public private(set) var connectedPeers: [Peer] = []
    @Published public private(set) var discoveredPeers: [DiscoveredPeer] = []
    @Published public private(set) var currentSession: PoolSession?
    @Published public private(set) var isHost: Bool = false

    /// Local user's profile
    @Published public var localProfile: PoolUserProfile = .defaultProfile

    // MARK: - Message Publishers

    /// Publisher for received messages
    public let messageReceived = PassthroughSubject<PoolMessage, Never>()

    /// Publisher for peer connection events
    public let peerEvent = PassthroughSubject<PeerEvent, Never>()

    // MARK: - Private Properties

    private var peerID: MCPeerID?
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    private var configuration: PoolConfiguration = .default
    private var pendingInvitations: [MCPeerID: (Bool, MCSession?) -> Void] = [:]

    /// Map MCPeerID to our Peer model
    private var peerIDMap: [MCPeerID: String] = [:]

    /// Track when each peer connected for DTLS stabilization checks
    private var peerConnectionTimes: [String: Date] = [:]

    /// Track failed join attempt counts per peer, persisted to UserDefaults with expiry.
    /// Each entry stores the count and the timestamp of the last failed attempt.
    private var failedAttemptCounts: [String: Int] = [:]

    /// Backing timestamps for failed attempt expiry (when each peer's count was last updated)
    private var failedAttemptTimestamps: [String: Date] = [:]

    /// Number of failed attempts before auto-blocking a device
    private static let maxFailedAttempts = 5

    /// UserDefaults key for persisted failed attempt counts
    private static let failedAttemptCountsKey = "com.stealthos.pool.failedAttemptCounts"

    /// Failed attempt counts older than this are expired and discarded (1 hour)
    private static let failedAttemptExpiry: TimeInterval = 3600

    /// Block list service for persistent device blocking
    private let blockListService = DeviceBlockListService.shared

    /// Tracked delayed tasks so they can be cancelled on disconnect
    private var delayedTasks: [Task<Void, Never>] = []

    /// Per-peer cooldown: tracks the last connection attempt timestamp per peer display name.
    /// Used to rate-limit invitation processing (5-second cooldown between attempts).
    private var lastAttemptTime: [String: Date] = [:]

    /// Minimum interval between connection attempts from the same peer (seconds)
    private static let attemptCooldownInterval: TimeInterval = 5.0

    /// Entries older than this are pruned from lastAttemptTime on each new attempt (seconds)
    private static let attemptTimestampExpiry: TimeInterval = 60.0

    /// Minimum delay after connection before DTLS is considered stable (milliseconds)
    private static let dtlsStabilizationDelay: Double = 2500

    // MARK: - Relay Advertising Properties

    /// Service type for relay discovery (separate from primary to avoid DTLS conflicts)
    private static let relayServiceType = "stealthos-rly"

    /// Advertiser for relay discovery (non-host members advertising the pool)
    private var relayAdvertiser: MCNearbyServiceAdvertiser?

    /// Dedicated MCSession for relay connections (completely isolated from primary session)
    private var relaySession: MCSession?

    /// Browser for discovering relay peers on the relay service type
    private var relayBrowser: MCNearbyServiceBrowser?

    /// Delegate handler for relay session events (separate from primary session delegate)
    private var relaySessionDelegate: RelaySessionDelegateHandler?

    /// Map MCPeerID from relay session to our Peer model
    private var relayPeerIDMap: [MCPeerID: String] = [:]

    /// Track connection times for relay peers (for DTLS stabilization)
    private var relayPeerConnectionTimes: [String: Date] = [:]

    /// Set of peer IDs connected via the relay session
    private var relayConnectedPeerIDs: Set<String> = []

    /// Whether this peer is advertising as a relay
    @Published public private(set) var isRelayAdvertising: Bool = false

    /// The peer we connected through if we joined via relay
    public private(set) var connectedViaRelayPeerID: String?

    /// Set of pool IDs we've already discovered (for deduplication)
    private var discoveredPoolIDs: Set<String> = []

    /// The discovered peer we're currently joining (stored for session creation on connect)
    private var joiningPeer: DiscoveredPeer?

    // MARK: - Initialization

    public override init() {
        super.init()
        setupPeerID()
        loadProfile()
        loadFailedAttemptCounts()
    }

    private func setupPeerID() {
        // Use device name or generate a unique name
        // NOTE: On macOS, Host.current().localizedName performs a synchronous reverse DNS lookup
        // that can block for 5-6 seconds if DNS is slow or fails. We use ProcessInfo.hostName
        // as the primary source which is faster and doesn't do reverse DNS.
        #if canImport(UIKit)
        let displayName = UIDevice.current.name
        #else
        let hostName = ProcessInfo.processInfo.hostName
        let displayName: String
        if !hostName.isEmpty && hostName != "localhost" {
            displayName = hostName
        } else {
            // Last resort: use Host.current() which may block on DNS
            displayName = Host.current().localizedName ?? "Mac User"
        }
        #endif
        self.peerID = MCPeerID(displayName: displayName)
    }

    /// Load user profile from UserDefaults (synchronous for immediate access)
    private func loadProfile() {
        let defaults = UserDefaults.standard
        let key = PoolUserProfile.storageKey

        // Try to load from UserDefaults first (synchronous)
        if let data = defaults.data(forKey: key),
           let savedProfile = try? JSONDecoder().decode(PoolUserProfile.self, from: data) {
            self.localProfile = savedProfile
            log("Loaded user profile from UserDefaults: \(savedProfile.displayName), emoji: \(savedProfile.avatarEmoji), color: \(savedProfile.avatarColorIndex)", category: .network)
        } else {
            log("No saved user profile found in UserDefaults, using default", category: .network)
        }
    }

    /// Save user profile to UserDefaults (synchronous for reliable persistence)
    public func saveProfile() {
        let defaults = UserDefaults.standard
        let key = PoolUserProfile.storageKey

        do {
            let data = try JSONEncoder().encode(localProfile)
            defaults.set(data, forKey: key)
            log("Saved user profile to UserDefaults: \(localProfile.displayName), emoji: \(localProfile.avatarEmoji), color: \(localProfile.avatarColorIndex)", category: .network)
        } catch {
            log("Failed to save user profile: \(error)", level: .error, category: .network)
        }
    }

    // MARK: - Failed Attempt Count Persistence

    /// Codable container for persisting failed attempt counts with timestamps.
    private struct PersistedFailedAttempt: Codable {
        let count: Int
        let lastUpdated: Date
    }

    /// Load persisted failed attempt counts from UserDefaults, discarding expired entries.
    private func loadFailedAttemptCounts() {
        guard let data = UserDefaults.standard.data(forKey: Self.failedAttemptCountsKey),
              let entries = try? JSONDecoder().decode([String: PersistedFailedAttempt].self, from: data) else {
            return
        }

        let now = Date()
        var loadedCounts: [String: Int] = [:]
        var loadedTimestamps: [String: Date] = [:]

        for (peerID, entry) in entries {
            // Discard entries older than the expiry window
            guard now.timeIntervalSince(entry.lastUpdated) < Self.failedAttemptExpiry else { continue }
            loadedCounts[peerID] = entry.count
            loadedTimestamps[peerID] = entry.lastUpdated
        }

        failedAttemptCounts = loadedCounts
        failedAttemptTimestamps = loadedTimestamps
        log("Loaded \(loadedCounts.count) persisted failed attempt counter(s) from UserDefaults", category: .network)
    }

    /// Persist current failed attempt counts to UserDefaults.
    private func saveFailedAttemptCounts() {
        var entries: [String: PersistedFailedAttempt] = [:]
        let now = Date()

        for (peerID, count) in failedAttemptCounts {
            let timestamp = failedAttemptTimestamps[peerID] ?? now
            // Only persist non-expired entries
            guard now.timeIntervalSince(timestamp) < Self.failedAttemptExpiry else { continue }
            entries[peerID] = PersistedFailedAttempt(count: count, lastUpdated: timestamp)
        }

        do {
            let data = try JSONEncoder().encode(entries)
            UserDefaults.standard.set(data, forKey: Self.failedAttemptCountsKey)
        } catch {
            log("Failed to save failed attempt counts: \(error)", level: .error, category: .network)
        }
    }

    /// Increment the failed attempt count for a peer, update timestamp, and persist.
    /// - Parameter peerID: The peer display name to increment.
    /// - Returns: The new count after incrementing.
    @discardableResult
    private func incrementFailedAttemptCount(for peerID: String) -> Int {
        let count = (failedAttemptCounts[peerID] ?? 0) + 1
        failedAttemptCounts[peerID] = count
        failedAttemptTimestamps[peerID] = Date()
        saveFailedAttemptCounts()
        return count
    }

    /// Remove the failed attempt count for a peer and persist.
    /// - Parameter peerID: The peer display name to clear.
    private func clearFailedAttemptCount(for peerID: String) {
        failedAttemptCounts.removeValue(forKey: peerID)
        failedAttemptTimestamps.removeValue(forKey: peerID)
        saveFailedAttemptCounts()
    }

    /// Update local profile and broadcast to connected peers
    public func updateProfile(_ profile: PoolUserProfile) {
        localProfile = profile
        saveProfile()
        broadcastProfile()
    }

    /// Broadcast current profile to all connected peers
    public func broadcastProfile() {
        guard let peerID = peerID else { return }

        log("[CALLER_TRACE] broadcastProfile() called", category: .network)
        let message = PoolMessage.profileUpdate(
            from: peerID.displayName,
            senderName: localProfile.displayName,
            profile: localProfile
        )
        sendMessage(message)
    }

    // MARK: - Public API

    /// Start hosting a new connection pool
    public func startHosting(configuration: PoolConfiguration = .default) {
        // If not idle, force cleanup first to prevent stale MC state
        if poolState != .idle {
            log("startHosting called while not idle (state: \(poolState)), forcing cleanup", level: .warning, category: .network)
            disconnect()
        }

        guard let peerID = peerID else {
            log("Cannot start hosting: peerID not initialized", category: .network)
            return
        }

        // Ensure any lingering session is fully cleaned up
        if session != nil {
            log("Cleaning up lingering session before hosting", level: .warning, category: .network)
            session?.delegate = nil
            session?.disconnect()
            session = nil
        }

        self.configuration = configuration
        self.isHost = true

        // Create session with encryption
        // CRITICAL FIX: Always use .required to match joiner side
        // Previously host used .optional which caused DTLS negotiation asymmetry
        let encryptionPreference: MCEncryptionPreference = .required
        log("[MC_SESSION] Creating host session with encryption: \(encryptionPreference == .required ? "required" : "optional")", category: .network)
        let newSession = MCSession(
            peer: peerID,
            securityIdentity: nil,
            encryptionPreference: encryptionPreference
        )
        newSession.delegate = self
        session = newSession
        log("[MC_SESSION] Host session created, delegate set", category: .network)

        // Generate pool code if requested
        let poolCode = configuration.generatePoolCode ? generatePoolCode() : nil

        // Create session info
        currentSession = PoolSession(
            name: configuration.name,
            hostPeerID: peerID.displayName,
            maxPeers: configuration.maxPeers,
            isEncrypted: configuration.requireEncryption,
            poolCode: poolCode
        )

        // Add self as host peer with profile
        let hostPeer = Peer(
            id: peerID.displayName,
            displayName: localProfile.displayName,
            isHost: true,
            status: .connected,
            profile: localProfile
        )
        connectedPeers = [hostPeer]

        // Start advertising with profile info
        var discoveryInfo: [String: String] = [
            "poolName": configuration.name,
            "poolID": currentSession!.id.uuidString,
            "maxPeers": String(configuration.maxPeers),
            "hostDisplayName": localProfile.displayName,
            "hostAvatarEmoji": localProfile.avatarEmoji,
            "hostAvatarColor": String(localProfile.avatarColorIndex),
            "supportsRelay": "true"
        ]
        // SECURITY: Never broadcast the actual pool code via Bonjour discovery.
        // Only advertise whether a code is required. The code is validated
        // server-side when the joiner sends it as invitation context.
        if poolCode != nil {
            discoveryInfo["hasPoolCode"] = "true"
        }

        advertiser = MCNearbyServiceAdvertiser(
            peer: peerID,
            discoveryInfo: discoveryInfo,
            serviceType: Self.serviceType
        )
        advertiser?.delegate = self
        log("[MC_ADVERTISER] Starting host advertiser for pool: \(configuration.name)", category: .network)
        advertiser?.startAdvertisingPeer()

        poolState = .hosting
        log("Started hosting pool: \(configuration.name)", category: .network)

        // Start relay advertising for the host as well
        // This allows peers that are out of the host's direct range but within range
        // of other connected peers to discover the pool. The relay advertiser uses a
        // separate service type and MCSession to avoid DTLS conflicts.
        let relayTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1000))
            if self.poolState == .hosting {
                self.startRelayAdvertising()
            }
        }
        delayedTasks.append(relayTask)
    }

    /// Start browsing for available pools
    public func startBrowsing() {
        // If not idle, force cleanup first to prevent stale MC state
        if poolState != .idle {
            log("startBrowsing called while not idle (state: \(poolState)), forcing cleanup", level: .warning, category: .network)
            disconnect()
        }

        guard let peerID = peerID else {
            log("Cannot start browsing: peerID not initialized", category: .network)
            return
        }

        // Ensure any lingering session is fully cleaned up
        if session != nil {
            log("Cleaning up lingering session before browsing", level: .warning, category: .network)
            session?.delegate = nil
            session?.disconnect()
            session = nil
        }

        self.isHost = false

        // Create session
        log("[MC_SESSION] Creating joiner session with encryption: required", category: .network)
        let newSession = MCSession(
            peer: peerID,
            securityIdentity: nil,
            encryptionPreference: .required
        )
        newSession.delegate = self
        session = newSession
        log("[MC_SESSION] Joiner session created, delegate set", category: .network)

        // Start browsing for direct host connections
        browser = MCNearbyServiceBrowser(
            peer: peerID,
            serviceType: Self.serviceType
        )
        browser?.delegate = self
        log("[MC_BROWSER] Starting browser for peer discovery", category: .network)
        browser?.startBrowsingForPeers()

        // Also browse for relay peers on the separate relay service type
        // This discovers non-host members who are extending the pool's discovery range
        relayBrowser = MCNearbyServiceBrowser(
            peer: peerID,
            serviceType: Self.relayServiceType
        )
        relayBrowser?.delegate = self
        log("[MC_BROWSER] Starting relay browser for relay peer discovery", category: .network)
        relayBrowser?.startBrowsingForPeers()

        discoveredPeers = []
        poolState = .browsing
        log("Started browsing for pools (primary + relay)", category: .network)
    }

    /// Join a discovered pool.
    /// - Parameters:
    ///   - peer: The discovered peer to join.
    ///   - poolCode: The pool code entered by the user, if the pool requires one.
    ///              Sent as invitation context and validated host-side.
    public func joinPool(_ peer: DiscoveredPeer, poolCode: String? = nil) {
        guard poolState == .browsing else {
            log("Cannot join pool: not in browsing state", category: .network)
            return
        }

        // Find the MCPeerID for this discovered peer
        guard let mcPeerID = peerIDMap.first(where: { $0.value == peer.id })?.key else {
            log("Cannot find MCPeerID for peer: \(peer.id)", category: .network)
            return
        }

        // Update state
        if let index = discoveredPeers.firstIndex(where: { $0.id == peer.id }) {
            discoveredPeers[index].isInviting = true
        }

        // Track if we're joining via a relay peer
        if peer.isRelay {
            connectedViaRelayPeerID = peer.id
            log("Joining pool via relay peer: \(peer.id)", category: .network)
        } else {
            connectedViaRelayPeerID = nil
        }

        // Store the joining peer info for session creation on successful connect
        joiningPeer = peer

        poolState = .connecting

        // SECURITY: Encode the pool code as invitation context so the host can validate it.
        // The code is never sent via Bonjour discovery info.
        let contextData: Data?
        if let poolCode = poolCode {
            let joinContext = JoinContext(poolCode: poolCode)
            contextData = try? JSONEncoder().encode(joinContext)
        } else {
            contextData = nil
        }

        if peer.isRelay {
            // Joining via relay: use a dedicated relay session to avoid DTLS conflicts
            // with the relay peer's primary pool session
            guard let localPeerID = peerID else {
                log("Cannot join pool via relay: peerID not initialized", category: .network)
                poolState = .browsing
                connectedViaRelayPeerID = nil
                return
            }

            // Create a dedicated relay session
            let newRelaySession = MCSession(
                peer: localPeerID,
                securityIdentity: nil,
                encryptionPreference: .required
            )
            let delegateHandler = RelaySessionDelegateHandler(manager: self)
            newRelaySession.delegate = delegateHandler
            relaySession = newRelaySession
            relaySessionDelegate = delegateHandler
            log("[MC_SESSION] Created relay joiner session for relay peer: \(peer.id)", category: .network)

            // Use relay browser to invite on the relay service type
            relayBrowser?.invitePeer(
                mcPeerID,
                to: newRelaySession,
                withContext: contextData,
                timeout: Self.invitationTimeout
            )

            log("Sent relay invitation to: \(peer.displayName) (relay)", category: .network)
        } else {
            // Direct join: use primary session
            guard let session = session else {
                log("Cannot join pool: session not initialized", category: .network)
                poolState = .browsing
                connectedViaRelayPeerID = nil
                return
            }

            browser?.invitePeer(
                mcPeerID,
                to: session,
                withContext: contextData,
                timeout: Self.invitationTimeout
            )

            log("Sent invitation to: \(peer.displayName)", category: .network)
        }
    }

    /// Send a message to all connected peers (primary session + relay session)
    public func sendMessage(_ message: PoolMessage) {
        // DIAGNOSTIC: Log ALL sendMessage calls with timestamp to identify DTLS error causes
        let timestamp = Date()
        let timeSinceEpoch = timestamp.timeIntervalSince1970
        log("[SEND_TRACE] sendMessage(broadcast) type=\(message.type.rawValue) at \(timestamp) (epoch: \(String(format: "%.3f", timeSinceEpoch)))", category: .network)

        guard let data = message.encode() else {
            log("Failed to encode message", category: .network)
            return
        }

        let mode: MCSessionSendDataMode = message.isReliable ? .reliable : .unreliable

        // Send via primary session
        if let session = session {
            let stablePeers = peersWithStableDTLS()
            let unstablePeers = session.connectedPeers.filter { !stablePeers.contains($0) }

            if !unstablePeers.isEmpty {
                let unstableNames = unstablePeers.map { $0.displayName }
                log("[DTLS_GUARD] Skipping \(unstablePeers.count) peers with unstable DTLS: \(unstableNames)", level: .warning, category: .network)
            }

            if !stablePeers.isEmpty {
                let peerNames = stablePeers.map { $0.displayName }
                log("[SEND_TRACE] Broadcasting \(message.type.rawValue) to stable primary peers: \(peerNames)", category: .network)

                do {
                    try session.send(data, toPeers: stablePeers, with: mode)
                    log("Sent message type: \(message.type.rawValue) to \(stablePeers.count) primary peers", category: .network)
                } catch {
                    log("[SEND_ERROR] Failed to send \(message.type.rawValue) to primary peers: \(error.localizedDescription)", level: .error, category: .network)
                }
            }
        }

        // Send via relay session to relay-connected peers
        if let relaySession = relaySession {
            let stableRelayPeers = relayPeersWithStableDTLS()

            if !stableRelayPeers.isEmpty {
                let relayPeerNames = stableRelayPeers.map { $0.displayName }
                log("[SEND_TRACE] Broadcasting \(message.type.rawValue) to stable relay peers: \(relayPeerNames)", category: .network)

                do {
                    try relaySession.send(data, toPeers: stableRelayPeers, with: mode)
                    log("Sent message type: \(message.type.rawValue) to \(stableRelayPeers.count) relay peers", category: .network)
                } catch {
                    log("[SEND_ERROR] Failed to send \(message.type.rawValue) to relay peers: \(error.localizedDescription)", level: .error, category: .network)
                }
            }
        }
    }

    /// Send a message to specific peers (checks both primary and relay sessions)
    public func sendMessage(_ message: PoolMessage, to peerIDs: [String]) {
        // DIAGNOSTIC: Log ALL sendMessage calls with timestamp to identify DTLS error causes
        let timestamp = Date()
        let timeSinceEpoch = timestamp.timeIntervalSince1970
        log("[SEND_TRACE] sendMessage(targeted) type=\(message.type.rawValue) to=\(peerIDs) at \(timestamp) (epoch: \(String(format: "%.3f", timeSinceEpoch)))", category: .network)

        guard let data = message.encode() else {
            log("Failed to encode message", category: .network)
            return
        }

        let mode: MCSessionSendDataMode = message.isReliable ? .reliable : .unreliable
        var sentToPrimary = 0
        var sentToRelay = 0

        // Try primary session first
        if let session = session {
            let targetPeers = session.connectedPeers.filter { mcPeer in
                peerIDs.contains(peerIDMap[mcPeer] ?? mcPeer.displayName)
            }

            // DTLS GUARD: Filter out peers with unstable DTLS connections
            let stablePeers = targetPeers.filter { mcPeer in
                let peerID = peerIDMap[mcPeer] ?? mcPeer.displayName
                return isDTLSStable(for: peerID)
            }
            let unstablePeers = targetPeers.filter { !stablePeers.contains($0) }

            if !unstablePeers.isEmpty {
                let unstableNames = unstablePeers.map { $0.displayName }
                log("[DTLS_GUARD] Skipping \(unstablePeers.count) targeted primary peers with unstable DTLS: \(unstableNames)", level: .warning, category: .network)
            }

            if !stablePeers.isEmpty {
                let targetNames = stablePeers.map { $0.displayName }
                log("[SEND_TRACE] Sending \(message.type.rawValue) to stable primary peers: \(targetNames)", category: .network)

                do {
                    try session.send(data, toPeers: stablePeers, with: mode)
                    sentToPrimary = stablePeers.count
                } catch {
                    log("[SEND_ERROR] Failed to send targeted \(message.type.rawValue) to primary peers \(targetNames): \(error.localizedDescription)", level: .error, category: .network)
                }
            }
        }

        // Check relay session for any remaining target peers
        if let relaySession = relaySession {
            // Find peers that are connected via relay session
            let relayTargetPeers = relaySession.connectedPeers.filter { mcPeer in
                peerIDs.contains(relayPeerIDMap[mcPeer] ?? mcPeer.displayName)
            }

            // DTLS GUARD for relay peers
            let stableRelayPeers = relayTargetPeers.filter { mcPeer in
                let peerID = relayPeerIDMap[mcPeer] ?? mcPeer.displayName
                return isRelayDTLSStable(for: peerID)
            }

            if !stableRelayPeers.isEmpty {
                let relayTargetNames = stableRelayPeers.map { $0.displayName }
                log("[SEND_TRACE] Sending \(message.type.rawValue) to stable relay peers: \(relayTargetNames)", category: .network)

                do {
                    try relaySession.send(data, toPeers: stableRelayPeers, with: mode)
                    sentToRelay = stableRelayPeers.count
                } catch {
                    log("[SEND_ERROR] Failed to send targeted \(message.type.rawValue) to relay peers \(relayTargetNames): \(error.localizedDescription)", level: .error, category: .network)
                }
            }
        }

        if sentToPrimary == 0 && sentToRelay == 0 {
            log("No matching reachable peers found for targeted message delivery to \(peerIDs)", level: .warning, category: .network)
        }
    }

    /// Send a chat message
    public func sendChat(_ text: String) {
        guard let peerID = peerID else {
            log("Cannot send chat: peerID not initialized", category: .network)
            return
        }

        log("[CALLER_TRACE] sendChat() called with text length: \(text.count)", category: .network)
        let message = PoolMessage.chat(
            from: peerID.displayName,
            senderName: localProfile.displayName,
            text: text
        )
        sendMessage(message)

        // Also publish locally so sender sees their own message
        messageReceived.send(message)
    }

    /// Disconnect from the current pool
    public func disconnect() {
        // CRITICAL: Nil delegates BEFORE stopping/disconnecting to prevent stale callbacks
        // This prevents "No route to host" errors from old session callbacks
        advertiser?.delegate = nil
        browser?.delegate = nil
        relayAdvertiser?.delegate = nil
        relayBrowser?.delegate = nil
        relaySession?.delegate = nil
        relaySessionDelegate = nil
        session?.delegate = nil

        // Stop advertising
        if advertiser != nil {
            log("[MC_ADVERTISER] Stopping advertiser in disconnect()", category: .network)
        }
        advertiser?.stopAdvertisingPeer()
        advertiser = nil

        // Stop browsing
        if browser != nil {
            log("[MC_BROWSER] Stopping browser in disconnect()", category: .network)
        }
        browser?.stopBrowsingForPeers()
        browser = nil

        // Stop relay advertising if active
        if relayAdvertiser != nil {
            log("[MC_ADVERTISER] Stopping relay advertiser in disconnect()", category: .network)
        }
        relayAdvertiser?.stopAdvertisingPeer()
        relayAdvertiser = nil
        isRelayAdvertising = false

        // Stop relay browsing if active
        if relayBrowser != nil {
            log("[MC_BROWSER] Stopping relay browser in disconnect()", category: .network)
        }
        relayBrowser?.stopBrowsingForPeers()
        relayBrowser = nil

        // Disconnect relay session
        if relaySession != nil {
            log("[MC_SESSION] Disconnecting relay session in disconnect()", category: .network)
        }
        relaySession?.disconnect()
        relaySession = nil

        // Disconnect primary session - the delegate is already nil'd so no stale callbacks
        if session != nil {
            log("[MC_SESSION] Disconnecting session in disconnect()", category: .network)
        }
        session?.disconnect()
        session = nil

        // Cancel all pending delayed tasks
        delayedTasks.forEach { $0.cancel() }
        delayedTasks.removeAll()

        // Clear state
        connectedPeers = []
        discoveredPeers = []
        currentSession = nil
        isHost = false
        peerIDMap = [:]
        peerConnectionTimes = [:]
        pendingInvitations = [:]
        // NOTE: failedAttemptCounts is intentionally NOT cleared on disconnect.
        // It is persisted to UserDefaults so brute-force counters survive pool recreation.
        lastAttemptTime = [:]
        connectedViaRelayPeerID = nil
        discoveredPoolIDs = []
        joiningPeer = nil
        relayPeerIDMap = [:]
        relayPeerConnectionTimes = [:]
        relayConnectedPeerIDs = []

        poolState = .idle
        log("Disconnected from pool - all MC state cleaned up", category: .network)
    }

    /// Reset all MultipeerConnectivity state and recreate peer ID
    /// Call this when experiencing stale connection issues (e.g., "No route to host" errors)
    public func reset() {
        // First perform full disconnect
        disconnect()

        // Recreate peer ID to ensure completely fresh MC state
        // This is the nuclear option that guarantees no stale internal MC state
        setupPeerID()

        log("ConnectionPoolManager fully reset with new peer ID", category: .network)
    }

    /// Get the local peer's display name (uses profile name, not device name)
    public var localPeerName: String {
        localProfile.displayName
    }

    /// Get the local peer's ID
    public var localPeerID: String {
        peerID?.displayName ?? ""
    }

    // MARK: - Device Blocking

    /// All currently blocked devices
    public var blockedDevices: [BlockedDevice] {
        blockListService.blockedDevices
    }

    /// Manually block a device and kick it if connected
    public func blockDevice(_ peerID: String, displayName: String) {
        blockListService.blockDevice(peerID, displayName: displayName, reason: .manual)

        // Kick the peer if currently connected
        if let mcPeerID = self.peerIDMap.first(where: { $0.value == peerID })?.key,
           let session = session {
            session.cancelConnectPeer(mcPeerID)
            removeConnectedPeer(mcPeerID)
            log("Kicked blocked peer: \(displayName)", category: .network)
        }

        // Reject any pending invitation from this peer
        if let mcPeerID = pendingInvitations.keys.first(where: { $0.displayName == peerID }) {
            pendingInvitations[mcPeerID]?(false, nil)
            pendingInvitations.removeValue(forKey: mcPeerID)
        }
    }

    /// Unblock a device
    public func unblockDevice(_ peerID: String) {
        blockListService.unblockDevice(peerID)
        clearFailedAttemptCount(for: peerID)
    }

    // MARK: - Relay Advertising

    /// Starts advertising this pool for relay discovery on a separate service type.
    ///
    /// FIX (2026-03): Uses `"stealthos-rly"` instead of `"stealthos-pool"` to avoid DTLS conflicts.
    /// A dedicated MCSession is created for relay connections, keeping the primary pool session
    /// completely untouched. This resolves the original DTLS crash from using the same service type.
    ///
    /// Original root cause (2024-01): Creating a second MCNearbyServiceAdvertiser with the same
    /// serviceType while having an active MCSession caused MultipeerConnectivity internal state
    /// conflicts and DTLS "No route to host" errors. Using a separate service type and session
    /// eliminates this entirely.
    public func startRelayAdvertising() {
        // Detailed logging to diagnose which guard condition fails
        if poolState != .connected && poolState != .hosting {
            log("Relay advertising guard failed: poolState is \(poolState), expected .connected or .hosting", level: .warning, category: .network)
        }
        if currentSession == nil {
            log("Relay advertising guard failed: currentSession is nil", level: .warning, category: .network)
        }
        if peerID == nil {
            log("Relay advertising guard failed: peerID is nil", level: .warning, category: .network)
        }

        guard poolState == .connected || poolState == .hosting,
              let currentSession = currentSession,
              let localPeerID = peerID else {
            log("Cannot start relay advertising: invalid state or missing session", level: .warning, category: .network)
            return
        }

        // Don't start if already advertising
        guard relayAdvertiser == nil else {
            log("Relay advertising already active", level: .debug, category: .network)
            return
        }

        // Build discovery info with relay flag
        var discoveryInfo: [String: String] = [
            "poolName": currentSession.name,
            "poolID": currentSession.id.uuidString,
            "isRelay": "true",
            "hostPeerID": currentSession.hostPeerID,
            "supportsRelay": "true",
            "maxPeers": String(currentSession.maxPeers)
        ]

        // SECURITY: Never broadcast the actual pool code via Bonjour discovery.
        // Only advertise whether a code is required.
        if currentSession.poolCode != nil {
            discoveryInfo["hasPoolCode"] = "true"
        }

        // Include our profile as relay info
        discoveryInfo["relayDisplayName"] = localProfile.displayName
        discoveryInfo["relayEmoji"] = localProfile.avatarEmoji
        discoveryInfo["relayColorIndex"] = String(localProfile.avatarColorIndex)

        // Create a dedicated MCSession for relay connections (completely separate from primary)
        // This is the key fix: the relay session is fully isolated so it cannot interfere
        // with the primary pool session's DTLS transport.
        if relaySession == nil {
            let newRelaySession = MCSession(
                peer: localPeerID,
                securityIdentity: nil,
                encryptionPreference: .required
            )
            let delegateHandler = RelaySessionDelegateHandler(manager: self)
            newRelaySession.delegate = delegateHandler
            relaySession = newRelaySession
            relaySessionDelegate = delegateHandler
            log("[MC_SESSION] Created dedicated relay session for relay advertising", category: .network)
        }

        // Advertise on the SEPARATE relay service type -- never on "stealthos-pool"
        relayAdvertiser = MCNearbyServiceAdvertiser(
            peer: localPeerID,
            discoveryInfo: discoveryInfo,
            serviceType: Self.relayServiceType
        )
        relayAdvertiser?.delegate = self
        relayAdvertiser?.startAdvertisingPeer()
        isRelayAdvertising = true

        log("Started relay advertising for pool: \(currentSession.name) on service type: \(Self.relayServiceType)", level: .info, category: .network)
    }

    /// Stops relay advertising and cleans up the relay session
    public func stopRelayAdvertising() {
        if relayAdvertiser != nil {
            // Nil delegate before stopping to prevent stale callbacks
            relayAdvertiser?.delegate = nil
            relayAdvertiser?.stopAdvertisingPeer()
            relayAdvertiser = nil
            log("Stopped relay advertising", level: .debug, category: .network)
        }

        // Clean up relay session if no relay peers are connected
        if relayConnectedPeerIDs.isEmpty {
            relaySession?.delegate = nil
            relaySessionDelegate = nil
            relaySession?.disconnect()
            relaySession = nil
            relayPeerIDMap = [:]
            relayPeerConnectionTimes = [:]
            log("Cleaned up relay session (no relay peers connected)", level: .debug, category: .network)
        }

        isRelayAdvertising = false
    }

    // MARK: - Private Helpers

    private func generatePoolCode() -> String {
        // Generate a 6-character alphanumeric code
        let characters = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") // Excluding similar chars like 0/O, 1/I
        return String((0..<6).compactMap { _ in characters.randomElement() })
    }

    private func updateConnectedPeer(_ mcPeerID: MCPeerID, status: PeerStatus) {
        let peerIDString = peerIDMap[mcPeerID] ?? mcPeerID.displayName

        if let index = connectedPeers.firstIndex(where: { $0.id == peerIDString }) {
            connectedPeers[index].status = status
        }
    }

    private func addConnectedPeer(_ mcPeerID: MCPeerID) {
        let peerIDString = mcPeerID.displayName
        peerIDMap[mcPeerID] = peerIDString

        // Record connection time for DTLS stabilization tracking
        peerConnectionTimes[peerIDString] = Date()

        // Don't add if already exists
        guard !connectedPeers.contains(where: { $0.id == peerIDString }) else {
            updateConnectedPeer(mcPeerID, status: .connected)
            return
        }

        // If we're not the host and this is our first peer, they must be the host
        // (we connected to them, so they're hosting the pool)
        let peerIsHost = !isHost && connectedPeers.isEmpty

        let peer = Peer(
            id: peerIDString,
            displayName: mcPeerID.displayName,
            isHost: peerIsHost,
            status: .connected
        )
        connectedPeers.append(peer)

        // Remove from discovered peers if present
        discoveredPeers.removeAll { $0.id == peerIDString }

        // Send our profile to the new peer after a delay
        // CRITICAL: MultipeerConnectivity reports .connected before the DTLS transport
        // is fully ready. Sending immediately causes "Failed to send DTLS packet" errors.
        // Testing showed 1000ms was insufficient - increased to 2500ms for reliable DTLS stabilization.
        // The DTLS handshake involves multiple round-trips and internal state updates.
        let targetPeerID = peerIDString
        let connectTime = Date()
        let profileTask = Task { @MainActor in
            log("[CALLER_TRACE] addConnectedPeer: starting 2500ms delay for profile update to \(targetPeerID) (connected at \(connectTime))", category: .network)
            try? await Task.sleep(for: .milliseconds(2500))
            // Verify peer is still connected before sending
            guard connectedPeers.contains(where: { $0.id == targetPeerID }) else {
                log("Peer \(targetPeerID) disconnected before profile could be sent", level: .debug, category: .network)
                return
            }
            let sendTime = Date()
            let elapsed = sendTime.timeIntervalSince(connectTime)
            log("[CALLER_TRACE] addConnectedPeer: sending profile update to \(targetPeerID) after \(String(format: "%.0f", elapsed * 1000))ms (DTLS stabilization complete)", category: .network)
            if let peerID = self.peerID {
                let message = PoolMessage.profileUpdate(
                    from: peerID.displayName,
                    senderName: localProfile.displayName,
                    profile: localProfile
                )
                sendMessage(message, to: [targetPeerID])
                log("Sent delayed profile update to \(targetPeerID)", level: .debug, category: .network)
            }
        }
        delayedTasks.append(profileTask)

        // Publish event
        peerEvent.send(.connected(peer))
    }

    /// Update a peer's profile
    public func updatePeerProfile(peerID: String, profile: PoolUserProfile) {
        if let index = connectedPeers.firstIndex(where: { $0.id == peerID }) {
            connectedPeers[index].profile = profile
        }
    }

    private func removeConnectedPeer(_ mcPeerID: MCPeerID) {
        let peerIDString = peerIDMap[mcPeerID] ?? mcPeerID.displayName

        if let peer = connectedPeers.first(where: { $0.id == peerIDString }) {
            connectedPeers.removeAll { $0.id == peerIDString }
            peerIDMap.removeValue(forKey: mcPeerID)
            peerConnectionTimes.removeValue(forKey: peerIDString)

            // Publish event
            peerEvent.send(.disconnected(peer))
        }
    }

    /// Check if a peer's DTLS transport has stabilized (sufficient time since connection)
    private func isDTLSStable(for peerID: String) -> Bool {
        guard let connectionTime = peerConnectionTimes[peerID] else {
            // If we don't have a connection time, assume it's stable (existing peer)
            return true
        }
        let elapsed = Date().timeIntervalSince(connectionTime) * 1000 // Convert to ms
        return elapsed >= Self.dtlsStabilizationDelay
    }

    /// Get list of peers with stable DTLS connections
    private func peersWithStableDTLS() -> [MCPeerID] {
        guard let session = session else { return [] }
        return session.connectedPeers.filter { mcPeer in
            let peerID = peerIDMap[mcPeer] ?? mcPeer.displayName
            return isDTLSStable(for: peerID)
        }
    }

    // MARK: - Relay Session DTLS Stability

    /// Check if a relay peer's DTLS transport has stabilized
    private func isRelayDTLSStable(for peerID: String) -> Bool {
        guard let connectionTime = relayPeerConnectionTimes[peerID] else {
            return true
        }
        let elapsed = Date().timeIntervalSince(connectionTime) * 1000
        return elapsed >= Self.dtlsStabilizationDelay
    }

    /// Get list of relay peers with stable DTLS connections
    private func relayPeersWithStableDTLS() -> [MCPeerID] {
        guard let relaySession = relaySession else { return [] }
        return relaySession.connectedPeers.filter { mcPeer in
            let peerID = relayPeerIDMap[mcPeer] ?? mcPeer.displayName
            return isRelayDTLSStable(for: peerID)
        }
    }

    // MARK: - Relay Peer Management (called by RelaySessionDelegateHandler)

    /// Called when a peer connects via the relay session
    func handleRelayPeerConnected(_ mcPeerID: MCPeerID) {
        let peerIDString = mcPeerID.displayName
        relayPeerIDMap[mcPeerID] = peerIDString
        relayPeerConnectionTimes[peerIDString] = Date()
        relayConnectedPeerIDs.insert(peerIDString)

        log("[RELAY_SESSION] Relay peer connected: \(peerIDString)", category: .network)

        // Add to connectedPeers as a relayed peer (if not already present)
        if !connectedPeers.contains(where: { $0.id == peerIDString }) {
            let peer = Peer(
                id: peerIDString,
                displayName: mcPeerID.displayName,
                isHost: false,
                status: .connected,
                supportsRelay: true,
                connectionType: .relayed
            )
            connectedPeers.append(peer)

            // Publish event
            peerEvent.send(.connected(peer))
        }

        // Send our profile to the relay peer after DTLS stabilization
        let connectTime = Date()
        let relayProfileTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(2500))
            guard self.relayConnectedPeerIDs.contains(peerIDString) else { return }
            let elapsed = Date().timeIntervalSince(connectTime)
            log("[RELAY_SESSION] Sending profile to relay peer \(peerIDString) after \(String(format: "%.0f", elapsed * 1000))ms", category: .network)
            if let localPeerID = self.peerID {
                let message = PoolMessage.profileUpdate(
                    from: localPeerID.displayName,
                    senderName: self.localProfile.displayName,
                    profile: self.localProfile
                )
                self.sendMessage(message, to: [peerIDString])
            }
        }
        delayedTasks.append(relayProfileTask)
    }

    /// Called when a peer disconnects from the relay session
    func handleRelayPeerDisconnected(_ mcPeerID: MCPeerID) {
        let peerIDString = relayPeerIDMap[mcPeerID] ?? mcPeerID.displayName
        relayPeerIDMap.removeValue(forKey: mcPeerID)
        relayPeerConnectionTimes.removeValue(forKey: peerIDString)
        relayConnectedPeerIDs.remove(peerIDString)

        log("[RELAY_SESSION] Relay peer disconnected: \(peerIDString)", category: .network)

        // Remove from connectedPeers if it was a relay-only peer
        if let peer = connectedPeers.first(where: { $0.id == peerIDString && $0.connectionType == .relayed }) {
            connectedPeers.removeAll { $0.id == peerIDString }
            peerEvent.send(.disconnected(peer))
        }

        // If no relay peers left, clean up relay session
        if relayConnectedPeerIDs.isEmpty && !isRelayAdvertising {
            relaySession?.delegate = nil
            relaySessionDelegate = nil
            relaySession?.disconnect()
            relaySession = nil
            log("[RELAY_SESSION] Cleaned up relay session - no relay peers remaining", category: .network)
        }
    }

    /// Called when data is received on the relay session
    func handleRelaySessionData(_ data: Data, from mcPeerID: MCPeerID) {
        let peerDisplayName = mcPeerID.displayName

        // SECURITY: Drop oversized payloads before JSON decoding to prevent memory exhaustion
        guard data.count <= Self.maxInboundMessageSize else {
            log("[SECURITY] Dropping oversized relay message from \(peerDisplayName): \(data.count) bytes exceeds \(Self.maxInboundMessageSize) byte limit",
                level: .warning, category: .network)
            return
        }

        guard let message = PoolMessage.decode(from: data) else {
            log("[RELAY_SESSION] Failed to decode message from relay peer: \(peerDisplayName)", category: .network)
            return
        }

        log("[RELAY_SESSION] Received \(message.type.rawValue) from relay peer: \(peerDisplayName)", category: .network)

        // Bridge the message to all primary session peers (forwarding)
        // This is the core relay bridging: messages from relay peers are forwarded to pool peers
        messageReceived.send(message)

        // Forward to primary session peers so they see relay peer messages
        if let session = session, !session.connectedPeers.isEmpty {
            if let encodedData = message.encode() {
                let stablePeers = peersWithStableDTLS()
                if !stablePeers.isEmpty {
                    do {
                        let mode: MCSessionSendDataMode = message.isReliable ? .reliable : .unreliable
                        try session.send(encodedData, toPeers: stablePeers, with: mode)
                        log("[RELAY_BRIDGE] Forwarded \(message.type.rawValue) from relay peer \(peerDisplayName) to \(stablePeers.count) primary peers", category: .network)
                    } catch {
                        log("[RELAY_BRIDGE] Failed to forward message to primary peers: \(error.localizedDescription)", level: .error, category: .network)
                    }
                }
            }
        }
    }

    /// Called when a relay peer is in connecting state
    func handleRelayPeerConnecting(_ mcPeerID: MCPeerID) {
        log("[RELAY_SESSION] Relay peer connecting: \(mcPeerID.displayName)", category: .network)
    }

    /// Called when a relay joiner successfully connects to a relay peer.
    /// This handles the pool session setup, browser cleanup, and self-registration
    /// that normally happens in the primary session delegate for direct connections.
    func handleRelayJoinerConnected(relayPeerDisplayName: String) {
        // Stop browsers on successful relay connection
        if browser != nil {
            log("[MC_FIX] Stopping browser on successful relay connection", category: .network)
            browser?.delegate = nil
            browser?.stopBrowsingForPeers()
            browser = nil
        }
        if relayBrowser != nil {
            log("[MC_FIX] Stopping relay browser on successful relay connection", category: .network)
            relayBrowser?.delegate = nil
            relayBrowser?.stopBrowsingForPeers()
            relayBrowser = nil
        }

        poolState = .connected

        // Create PoolSession for relay joiner
        if !isHost, currentSession == nil, let joining = joiningPeer {
            let hostID = joining.hostPeerID ?? relayPeerDisplayName
            let poolID: UUID
            if let poolIDString = joining.poolID, let parsed = UUID(uuidString: poolIDString) {
                poolID = parsed
            } else {
                poolID = UUID()
            }

            currentSession = PoolSession(
                id: poolID,
                name: joining.displayName,
                hostPeerID: hostID,
                isEncrypted: true
                // Note: joiners do not store the pool code -- only the host has it
            )

            log("[RELAY_SESSION] Created PoolSession for relay joiner: name=\(joining.displayName), poolID=\(poolID), hostPeerID=\(hostID)", category: .network)
            joiningPeer = nil
        }

        // Add self to connectedPeers for relay joiner
        if !isHost, let selfPeerID = self.peerID {
            let selfPeerIDString = selfPeerID.displayName
            if !connectedPeers.contains(where: { $0.id == selfPeerIDString }) {
                let selfPeer = Peer(
                    id: selfPeerIDString,
                    displayName: localProfile.displayName,
                    isHost: false,
                    status: .connected,
                    profile: localProfile,
                    connectionType: .relayed
                )
                connectedPeers.insert(selfPeer, at: 0)
                log("[RELAY_SESSION] Added self to connectedPeers for relay joiner: \(selfPeerIDString)", category: .network)
            }
        }

        // Start relay advertising after delay (extending discovery range further)
        if !isHost {
            let relayAdvTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(3000))
                if self.poolState == .connected && !self.isHost {
                    self.startRelayAdvertising()
                }
            }
            delayedTasks.append(relayAdvTask)
        }
    }

    /// Called when a relay joiner loses connection to the relay peer
    func handleRelayJoinerDisconnected(relayPeerDisplayName: String) {
        // If we were connecting, go back to browsing
        if poolState == .connecting {
            poolState = .browsing
        }

        // If no primary peers either, disconnect entirely
        if connectedPeers.count <= 1 { // Only self in list
            disconnect()
        }
    }
}

// MARK: - MCSessionDelegate

extension ConnectionPoolManager: MCSessionDelegate {

    nonisolated public func session(
        _ session: MCSession,
        peer peerID: MCPeerID,
        didChange state: MCSessionState
    ) {
        // Capture values before entering async context to avoid data race
        let peerDisplayName = peerID.displayName
        let capturedPeerID = peerID

        Task { @MainActor [capturedPeerID] in
            switch state {
            case .notConnected:
                let disconnectTime = Date()
                log("[PEER_STATE] Peer disconnected: \(peerDisplayName) at \(disconnectTime) (epoch: \(String(format: "%.3f", disconnectTime.timeIntervalSince1970)))", category: .network)
                removeConnectedPeer(capturedPeerID)

                // If we were connecting and lost connection, go back to browsing
                if poolState == .connecting {
                    poolState = .browsing
                }

                // If all peers disconnected and we're not host, go idle
                if !isHost && connectedPeers.isEmpty {
                    disconnect()
                }

            case .connecting:
                log("Peer connecting: \(peerDisplayName)", category: .network)
                updateConnectedPeer(capturedPeerID, status: .connecting)

            case .connected:
                let connectTime = Date()
                log("[PEER_STATE] Peer connected: \(peerDisplayName) at \(connectTime) (epoch: \(String(format: "%.3f", connectTime.timeIntervalSince1970))) isHost=\(isHost)", category: .network)
                log("[MC_INTERNAL] DTLS transport may still be stabilizing. Internal MC operations (keepalive, DTLS renegotiation) can cause errors for ~2-3s after this point even without app-level sends.", category: .network)

                // HOST-SIDE FIX: Ensure advertiser is stopped on successful connection
                // This is a safety net in case it wasn't stopped during invitation acceptance
                // (e.g., if manual invitation handling is used instead of auto-accept)
                if isHost && advertiser != nil {
                    log("[MC_ADVERTISER] HOST: Stopping advertiser on peer connection (safety net)", category: .network)
                    advertiser?.delegate = nil
                    advertiser?.stopAdvertisingPeer()
                    advertiser = nil
                }

                addConnectedPeer(capturedPeerID)

                // Update pool state if we were connecting
                if poolState == .connecting {
                    // CRITICAL FIX: Stop browser immediately on successful connection
                    // Keeping the browser active causes MultipeerConnectivity internal state conflicts:
                    // - Multiple participant IDs being tracked internally
                    // - "no clist for remoteID" errors from stale internal state
                    // - "Not in connected state" errors as MC tries to reconcile browser/session state
                    // - DTLS "No route to host" failures from conflicting transport state
                    // The browser MUST be stopped before we do anything else with the session.
                    if browser != nil {
                        log("[MC_FIX] Stopping browser on successful connection to prevent MC state conflicts", category: .network)
                        browser?.delegate = nil
                        browser?.stopBrowsingForPeers()
                        browser = nil
                    }

                    // Also stop relay browser on direct connection success
                    if relayBrowser != nil {
                        log("[MC_FIX] Stopping relay browser on successful direct connection", category: .network)
                        relayBrowser?.delegate = nil
                        relayBrowser?.stopBrowsingForPeers()
                        relayBrowser = nil
                    }

                    poolState = .connected

                    // FIX: Create PoolSession for non-host peers on successful connection
                    // The session info comes from the DiscoveredPeer we stored in joinPool()
                    if !isHost, currentSession == nil, let joining = joiningPeer {
                        // Determine the host peer ID (either explicit from discovery or the peer we connected to)
                        let hostID = joining.hostPeerID ?? peerDisplayName

                        // Parse pool ID from discovery info, or generate a new one
                        let poolID: UUID
                        if let poolIDString = joining.poolID, let parsed = UUID(uuidString: poolIDString) {
                            poolID = parsed
                        } else {
                            poolID = UUID()
                        }

                        // Create the session with info from discovery
                        currentSession = PoolSession(
                            id: poolID,
                            name: joining.displayName, // This is the pool name from discovery
                            hostPeerID: hostID,
                            isEncrypted: true // Assume encrypted
                            // Note: joiners do not store the pool code -- only the host has it
                        )

                        log("Created PoolSession for non-host peer: name=\(joining.displayName), poolID=\(poolID), hostPeerID=\(hostID)", category: .network)

                        // Clear the joining peer reference
                        joiningPeer = nil
                    }

                    // FIX: Add self to connectedPeers for non-host peers
                    // The host adds themselves when hosting starts (line 222-229), but
                    // joiners never did - causing them to not see their own account in the UI
                    if !isHost, let selfPeerID = self.peerID {
                        let selfPeerIDString = selfPeerID.displayName
                        if !connectedPeers.contains(where: { $0.id == selfPeerIDString }) {
                            let selfPeer = Peer(
                                id: selfPeerIDString,
                                displayName: localProfile.displayName,
                                isHost: false,
                                status: .connected,
                                profile: localProfile
                            )
                            connectedPeers.insert(selfPeer, at: 0) // Insert at beginning so self appears first
                            log("Added self to connectedPeers for non-host peer: \(selfPeerIDString)", category: .network)
                        }
                    }

                    // Start relay advertising if we're not the host
                    // This allows new peers to discover the pool through us
                    // Delay relay advertising to ensure MultipeerConnectivity internal state
                    // is fully stabilized after connection (fixes "Not in connected state" errors)
                    if !isHost {
                        let delayedRelayTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(3000))
                            // Re-check conditions after delay since state may have changed
                            if poolState == .connected && !isHost {
                                startRelayAdvertising()
                            }
                        }
                        delayedTasks.append(delayedRelayTask)
                    }
                }

            @unknown default:
                log("Unknown peer state: \(peerDisplayName)", category: .network)
            }
        }
    }

    /// Maximum allowed inbound message size (10 MB). Messages exceeding this are dropped before decoding.
    /// nonisolated so it can be accessed from nonisolated MCSessionDelegate callbacks.
    nonisolated private static let maxInboundMessageSize = 10 * 1024 * 1024

    nonisolated public func session(
        _ session: MCSession,
        didReceive data: Data,
        fromPeer peerID: MCPeerID
    ) {
        let peerDisplayName = peerID.displayName

        // SECURITY: Drop oversized payloads before JSON decoding to prevent memory exhaustion
        guard data.count <= Self.maxInboundMessageSize else {
            Task { @MainActor in
                log("[SECURITY] Dropping oversized message from \(peerDisplayName): \(data.count) bytes exceeds \(Self.maxInboundMessageSize) byte limit",
                    level: .warning, category: .network)
            }
            return
        }

        guard let message = PoolMessage.decode(from: data) else {
            Task { @MainActor in
                log("Failed to decode received message", category: .network)
            }
            return
        }

        Task { @MainActor in
            let receiveTime = Date()
            log("[RECV_TRACE] Received message type=\(message.type.rawValue) from \(peerDisplayName) at \(receiveTime) (epoch: \(String(format: "%.3f", receiveTime.timeIntervalSince1970)))", category: .network)
            messageReceived.send(message)

            // Bridge: Forward messages from primary peers to relay-connected peers
            // This enables relay-connected peers to receive messages from all pool members
            if let relaySession = self.relaySession, !self.relayConnectedPeerIDs.isEmpty {
                let stableRelayPeers = self.relayPeersWithStableDTLS()
                if !stableRelayPeers.isEmpty {
                    do {
                        let mode: MCSessionSendDataMode = message.isReliable ? .reliable : .unreliable
                        try relaySession.send(data, toPeers: stableRelayPeers, with: mode)
                        log("[RELAY_BRIDGE] Forwarded \(message.type.rawValue) from primary peer \(peerDisplayName) to \(stableRelayPeers.count) relay peers", category: .network)
                    } catch {
                        log("[RELAY_BRIDGE] Failed to forward to relay peers: \(error.localizedDescription)", level: .error, category: .network)
                    }
                }
            }
        }
    }

    nonisolated public func session(
        _ session: MCSession,
        didReceive stream: InputStream,
        withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {
        let peerDisplayName = peerID.displayName
        Task { @MainActor in
            log("Received stream: \(streamName) from \(peerDisplayName)", category: .network)
        }
    }

    nonisolated public func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {
        let peerDisplayName = peerID.displayName
        Task { @MainActor in
            log("Started receiving resource: \(resourceName) from \(peerDisplayName)", category: .network)
        }
    }

    nonisolated public func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: Error?
    ) {
        Task { @MainActor in
            if let error = error {
                log("Failed to receive resource: \(error.localizedDescription)", category: .network)
            } else {
                log("Finished receiving resource: \(resourceName)", category: .network)
            }
        }
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension ConnectionPoolManager: MCNearbyServiceAdvertiserDelegate {

    nonisolated public func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        let peerDisplayName = peerID.displayName
        let capturedPeerID = peerID
        // Wrap the handler in a sendable container
        let handler = UncheckedSendableBox(invitationHandler)

        Task { @MainActor [capturedPeerID] in
            // SECURITY: Per-peer rate limiting — reject if this peer attempted within the cooldown window.
            // Prune old entries (older than 60s) on each new attempt to prevent unbounded growth.
            let now = Date()
            let expiryCutoff = now.addingTimeInterval(-Self.attemptTimestampExpiry)
            self.lastAttemptTime = self.lastAttemptTime.filter { $0.value > expiryCutoff }

            if let lastTime = self.lastAttemptTime[peerDisplayName],
               now.timeIntervalSince(lastTime) < Self.attemptCooldownInterval {
                log("[SECURITY] Rate-limiting invitation from \(peerDisplayName): attempted \(String(format: "%.1f", now.timeIntervalSince(lastTime)))s ago (cooldown: \(Self.attemptCooldownInterval)s)",
                    level: .warning, category: .network)
                handler.value(false, nil as MCSession?)
                return
            }
            self.lastAttemptTime[peerDisplayName] = now

            // Determine if this invitation came via the relay advertiser
            let isRelayInvitation = advertiser === self.relayAdvertiser

            if isRelayInvitation {
                log("[RELAY_ADV] Received relay invitation from: \(peerDisplayName)", category: .network)

                // Check if device is blocked
                if blockListService.isBlocked(peerDisplayName) {
                    log("[RELAY_ADV] Rejecting relay invitation from blocked device: \(peerDisplayName)", category: .network)
                    handler.value(false, nil as MCSession?)
                    return
                }

                // SECURITY: Validate pool code from invitation context (host-side validation)
                if let requiredCode = self.currentSession?.poolCode {
                    let providedCode: String?
                    if let contextData = context,
                       let joinContext = try? JSONDecoder().decode(JoinContext.self, from: contextData) {
                        providedCode = joinContext.poolCode
                    } else {
                        providedCode = nil
                    }

                    if providedCode?.uppercased() != requiredCode.uppercased() {
                        log("[RELAY_ADV] Rejecting relay invitation: invalid pool code from \(peerDisplayName)", category: .network)
                        handler.value(false, nil as MCSession?)

                        // Track failed code attempts for brute-force protection
                        let count = self.incrementFailedAttemptCount(for: peerDisplayName)
                        log("Failed code attempt count for \(peerDisplayName): \(count)/\(Self.maxFailedAttempts)", category: .network)
                        if count >= Self.maxFailedAttempts {
                            self.blockListService.blockDevice(peerDisplayName, displayName: peerDisplayName, reason: .bruteForce)
                            self.clearFailedAttemptCount(for: peerDisplayName)
                            self.peerEvent.send(.deviceAutoBlocked(peerDisplayName))
                            log("Auto-blocked device after \(Self.maxFailedAttempts) failed code attempts (relay): \(peerDisplayName)", level: .warning, category: .network)
                        }
                        return
                    }
                }

                guard let relaySession = self.relaySession else {
                    log("[RELAY_ADV] No relay session available, rejecting relay invitation", level: .warning, category: .network)
                    handler.value(false, nil as MCSession?)
                    return
                }

                handler.value(true, relaySession)
                // Reset failed attempts on successful join
                self.clearFailedAttemptCount(for: peerDisplayName)
                log("[RELAY_ADV] Accepted relay invitation from: \(peerDisplayName) into relay session", category: .network)
                return
            }

            // Primary advertiser invitation handling
            log("Received invitation from: \(peerDisplayName)", category: .network)

            // Check if device is blocked - reject immediately without counting as a failed attempt
            if blockListService.isBlocked(peerDisplayName) {
                log("Rejecting invitation from blocked device: \(peerDisplayName)", category: .network)
                handler.value(false, nil as MCSession?)
                peerEvent.send(.invitationRejectedBlocked(peerDisplayName))
                return
            }

            // SECURITY: Validate pool code from invitation context (host-side validation)
            // This is the authoritative check. The code is never in discovery info.
            if let requiredCode = self.currentSession?.poolCode {
                let providedCode: String?
                if let contextData = context,
                   let joinContext = try? JSONDecoder().decode(JoinContext.self, from: contextData) {
                    providedCode = joinContext.poolCode
                } else {
                    providedCode = nil
                }

                if providedCode?.uppercased() != requiredCode.uppercased() {
                    log("Rejecting invitation: invalid pool code from \(peerDisplayName)", category: .network)
                    handler.value(false, nil as MCSession?)

                    // Track failed code attempts for brute-force protection
                    let count = self.incrementFailedAttemptCount(for: peerDisplayName)
                    log("Failed code attempt count for \(peerDisplayName): \(count)/\(Self.maxFailedAttempts)", category: .network)
                    if count >= Self.maxFailedAttempts {
                        self.blockListService.blockDevice(peerDisplayName, displayName: peerDisplayName, reason: .bruteForce)
                        self.clearFailedAttemptCount(for: peerDisplayName)
                        self.peerEvent.send(.deviceAutoBlocked(peerDisplayName))
                        log("Auto-blocked device after \(Self.maxFailedAttempts) failed code attempts: \(peerDisplayName)", level: .warning, category: .network)
                    }
                    return
                }
            }

            // Check if we can accept more peers (pool full is not the device's fault, don't count)
            guard connectedPeers.count < configuration.maxPeers else {
                log("Rejecting invitation: pool is full", category: .network)
                handler.value(false, nil as MCSession?)
                return
            }

            if configuration.autoAcceptInvitations {
                // CRITICAL FIX: Stop advertiser BEFORE accepting invitation
                // Keeping the advertiser active while accepting connections causes MC internal state conflicts:
                // - "no clist for remoteID" errors from conflicting participant tracking
                // - DTLS "No route to host" failures from transport state conflicts
                // - The advertiser continues to process discovery even during DTLS handshake
                // This is analogous to how browser is stopped on joiner side when connection succeeds.
                if self.advertiser != nil {
                    log("[MC_ADVERTISER] Stopping advertiser before accepting invitation (prevents MC state conflicts)", category: .network)
                    self.advertiser?.delegate = nil
                    self.advertiser?.stopAdvertisingPeer()
                    self.advertiser = nil
                }

                // Auto-accept (pool code was already validated above if required)
                handler.value(true, self.session)
                // Reset failed attempts on successful join
                self.clearFailedAttemptCount(for: peerDisplayName)
                log("Auto-accepted invitation from: \(peerDisplayName)", category: .network)
            } else {
                // Store for manual handling
                pendingInvitations[capturedPeerID] = handler.value

                // Publish event for UI to handle
                let peer = DiscoveredPeer(
                    id: peerDisplayName,
                    displayName: peerDisplayName
                )
                peerEvent.send(.invitationReceived(peer))
            }
        }
    }

    nonisolated public func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didNotStartAdvertisingPeer error: Error
    ) {
        let errorDescription = error.localizedDescription
        Task { @MainActor in
            // Determine if this is the host advertiser or relay advertiser
            let isRelayAdvertiserError = advertiser === relayAdvertiser

            if isRelayAdvertiserError {
                // Relay advertising failure is non-fatal - just log and clean up
                log("Failed to start relay advertising: \(errorDescription)", level: .warning, category: .network)
                relayAdvertiser = nil
                isRelayAdvertising = false
            } else {
                // Host advertising failure is critical
                // SECURITY: Log the full error for diagnostics but show a generic message to the user
                // to avoid leaking internal framework details (paths, addresses, etc.)
                log("Failed to start hosting: \(errorDescription)", level: .error, category: .network)
                poolState = .error("Failed to start hosting. Please try again.")
            }
        }
    }

    /// Accept a pending invitation
    public func acceptInvitation(from peerID: String) {
        guard let mcPeerID = peerIDMap.first(where: { $0.value == peerID })?.key ?? pendingInvitations.keys.first(where: { $0.displayName == peerID }),
              let handler = pendingInvitations[mcPeerID] else {
            log("No pending invitation from: \(peerID)", category: .network)
            return
        }

        handler(true, session)
        pendingInvitations.removeValue(forKey: mcPeerID)
        // Reset failed attempts on successful join
        clearFailedAttemptCount(for: peerID)
        log("Accepted invitation from: \(peerID)", category: .network)
    }

    /// Reject a pending invitation
    public func rejectInvitation(from peerID: String) {
        guard let mcPeerID = peerIDMap.first(where: { $0.value == peerID })?.key ?? pendingInvitations.keys.first(where: { $0.displayName == peerID }),
              let handler = pendingInvitations[mcPeerID] else {
            log("No pending invitation from: \(peerID)", category: .network)
            return
        }

        handler(false, nil)
        pendingInvitations.removeValue(forKey: mcPeerID)
        log("Rejected invitation from: \(peerID)", category: .network)

        // Increment failed attempt counter (manual rejection counts)
        let count = incrementFailedAttemptCount(for: peerID)
        log("Failed attempt count for \(peerID): \(count)/\(Self.maxFailedAttempts)", category: .network)

        // Auto-block at threshold
        if count >= Self.maxFailedAttempts {
            let displayName = mcPeerID.displayName
            blockListService.blockDevice(peerID, displayName: displayName, reason: .bruteForce)
            clearFailedAttemptCount(for: peerID)
            peerEvent.send(.deviceAutoBlocked(displayName))
            log("Auto-blocked device after \(Self.maxFailedAttempts) failed attempts: \(displayName)", level: .warning, category: .network)
        }
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension ConnectionPoolManager: MCNearbyServiceBrowserDelegate {

    nonisolated public func browser(
        _ browser: MCNearbyServiceBrowser,
        foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String: String]?
    ) {
        let peerDisplayName = peerID.displayName
        let poolName = info?["poolName"] ?? "Unknown Pool"
        let hasPoolCode = info?["hasPoolCode"] == "true"
        let poolID = info?["poolID"]
        let capturedPeerID = peerID

        // Check if this is a relay peer advertisement
        let isRelayPeer = info?["isRelay"] == "true"
        let hostPeerID = info?["hostPeerID"]
        let supportsRelay = info?["supportsRelay"] == "true"

        // Parse host profile from discovery info (direct host advertisement)
        let hostProfile: PoolUserProfile?
        if let hostDisplayName = info?["hostDisplayName"],
           let avatarEmoji = info?["hostAvatarEmoji"],
           let avatarColorStr = info?["hostAvatarColor"],
           let avatarColorIndex = Int(avatarColorStr) {
            hostProfile = PoolUserProfile(
                displayName: hostDisplayName,
                avatarEmoji: avatarEmoji,
                avatarColorIndex: avatarColorIndex
            )
        } else {
            hostProfile = nil
        }

        // Parse relay peer profile if this is a relay advertisement
        let relayProfile: PoolUserProfile?
        if isRelayPeer,
           let relayDisplayName = info?["relayDisplayName"],
           let relayEmoji = info?["relayEmoji"],
           let relayColorStr = info?["relayColorIndex"],
           let relayColorIndex = Int(relayColorStr) {
            relayProfile = PoolUserProfile(
                displayName: relayDisplayName,
                avatarEmoji: relayEmoji,
                avatarColorIndex: relayColorIndex
            )
        } else {
            relayProfile = nil
        }

        Task { @MainActor [capturedPeerID] in
            // Store mapping
            peerIDMap[capturedPeerID] = peerDisplayName

            // Deduplicate by pool ID if available
            // If we've already discovered this pool (via host or another relay), skip
            if let poolID = poolID {
                if discoveredPoolIDs.contains(poolID) {
                    log("Skipping duplicate pool discovery via \(isRelayPeer ? "relay" : "host"): \(poolName) (poolID: \(poolID))", level: .debug, category: .network)
                    return
                }
                discoveredPoolIDs.insert(poolID)
            }

            // Also skip if we already have this exact peer
            guard !discoveredPeers.contains(where: { $0.id == peerDisplayName }) else {
                log("Skipping already discovered peer: \(peerDisplayName)", level: .debug, category: .network)
                return
            }

            if isRelayPeer {
                log("Found relay peer: \(peerDisplayName) advertising pool: \(poolName) (host: \(hostPeerID ?? "unknown"))", category: .network)
            } else {
                log("Found peer: \(peerDisplayName) hosting: \(poolName)", category: .network)
            }

            let peer = DiscoveredPeer(
                id: peerDisplayName,
                displayName: poolName,
                hasPoolCode: hasPoolCode,
                hostProfile: hostProfile,
                isRelay: isRelayPeer,
                relayProfile: relayProfile,
                hostPeerID: hostPeerID,
                poolID: poolID,
                supportsRelay: supportsRelay
            )
            discoveredPeers.append(peer)
        }
    }

    nonisolated public func browser(
        _ browser: MCNearbyServiceBrowser,
        lostPeer peerID: MCPeerID
    ) {
        let peerDisplayName = peerID.displayName
        let capturedPeerID = peerID

        Task { @MainActor [capturedPeerID] in
            log("Lost peer: \(peerDisplayName)", category: .network)

            // Remove from discovered pool IDs if this was the only source for that pool
            if let lostPeer = discoveredPeers.first(where: { $0.id == peerDisplayName }),
               let poolID = lostPeer.poolID {
                // Check if there are other peers advertising the same pool
                let otherPeersForPool = discoveredPeers.filter { $0.poolID == poolID && $0.id != peerDisplayName }
                if otherPeersForPool.isEmpty {
                    discoveredPoolIDs.remove(poolID)
                }
            }

            discoveredPeers.removeAll { $0.id == peerDisplayName }
            peerIDMap.removeValue(forKey: capturedPeerID)
        }
    }

    nonisolated public func browser(
        _ browser: MCNearbyServiceBrowser,
        didNotStartBrowsingForPeers error: Error
    ) {
        let errorDescription = error.localizedDescription
        Task { @MainActor in
            // Determine if this is the relay browser or primary browser
            let isRelayBrowserError = browser === self.relayBrowser

            if isRelayBrowserError {
                // Relay browser failure is non-fatal - just log and clean up
                log("[RELAY_BROWSER] Failed to start relay browsing: \(errorDescription)", level: .warning, category: .network)
                self.relayBrowser = nil
            } else {
                // Primary browser failure is critical
                // SECURITY: Log the full error for diagnostics but show a generic message to the user
                // to avoid leaking internal framework details (paths, addresses, etc.)
                log("Failed to start browsing: \(errorDescription)", level: .error, category: .network)
                poolState = .error("Failed to browse for pools. Please try again.")
            }
        }
    }
}

// MARK: - Peer Events

/// Events related to peer connections
public enum PeerEvent: Sendable {
    case connected(Peer)
    case disconnected(Peer)
    case invitationReceived(DiscoveredPeer)
    case invitationRejectedBlocked(String)
    case deviceAutoBlocked(String)
}

// MARK: - Join Context

/// Context data sent with MC invitations for host-side pool code validation.
///
/// SECURITY: The pool code is transmitted only via the DTLS-encrypted MC invitation
/// context, never via Bonjour discovery info. This prevents passive eavesdropping
/// of pool codes by nearby devices that are merely browsing.
public struct JoinContext: Codable, Sendable {
    /// The pool code entered by the user attempting to join.
    public let poolCode: String

    public init(poolCode: String) {
        self.poolCode = poolCode
    }
}

// MARK: - Relay Session Delegate Handler

/// Separate delegate handler for the relay MCSession.
///
/// MultipeerConnectivity requires each MCSession to have its own delegate instance.
/// Since `ConnectionPoolManager` already conforms to `MCSessionDelegate` for the primary
/// session, this class provides an isolated delegate for the relay session and forwards
/// events to the manager via MainActor-dispatched calls.
///
/// This separation is critical for the DTLS fix: the relay session's transport layer
/// is completely independent from the primary session, preventing the state conflicts
/// that caused the original crashes.
///
/// SAFETY: @unchecked Sendable because MCSessionDelegate methods are nonisolated
/// and we only access the weak manager reference via MainActor dispatch.
final class RelaySessionDelegateHandler: NSObject, MCSessionDelegate, @unchecked Sendable {

    private weak var manager: ConnectionPoolManager?

    init(manager: ConnectionPoolManager) {
        self.manager = manager
        super.init()
    }

    nonisolated func session(
        _ session: MCSession,
        peer peerID: MCPeerID,
        didChange state: MCSessionState
    ) {
        let peerDisplayName = peerID.displayName
        let capturedPeerID = peerID

        Task { @MainActor [weak self, capturedPeerID] in
            guard let manager = self?.manager else { return }

            switch state {
            case .notConnected:
                log("[RELAY_SESSION] Peer disconnected: \(peerDisplayName)", category: .network)
                manager.handleRelayPeerDisconnected(capturedPeerID)

                // If we joined via relay and the relay peer disconnected, handle gracefully
                if manager.connectedViaRelayPeerID == peerDisplayName {
                    log("[RELAY_SESSION] Lost relay connection to pool - relay peer disconnected", level: .warning, category: .network)
                    manager.handleRelayJoinerDisconnected(relayPeerDisplayName: peerDisplayName)
                }

            case .connecting:
                manager.handleRelayPeerConnecting(capturedPeerID)

            case .connected:
                log("[RELAY_SESSION] Peer connected: \(peerDisplayName)", category: .network)
                manager.handleRelayPeerConnected(capturedPeerID)

                // If we were joining via relay, complete the connection setup
                if manager.poolState == .connecting && manager.connectedViaRelayPeerID != nil {
                    manager.handleRelayJoinerConnected(relayPeerDisplayName: peerDisplayName)
                }

            @unknown default:
                log("[RELAY_SESSION] Unknown peer state: \(peerDisplayName)", category: .network)
            }
        }
    }

    nonisolated func session(
        _ session: MCSession,
        didReceive data: Data,
        fromPeer peerID: MCPeerID
    ) {
        let capturedPeerID = peerID
        Task { @MainActor [weak self] in
            self?.manager?.handleRelaySessionData(data, from: capturedPeerID)
        }
    }

    nonisolated func session(
        _ session: MCSession,
        didReceive stream: InputStream,
        withName streamName: String,
        fromPeer peerID: MCPeerID
    ) {
        Task { @MainActor in
            log("[RELAY_SESSION] Received stream: \(streamName) from \(peerID.displayName)", category: .network)
        }
    }

    nonisolated func session(
        _ session: MCSession,
        didStartReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        with progress: Progress
    ) {
        Task { @MainActor in
            log("[RELAY_SESSION] Started receiving resource: \(resourceName) from \(peerID.displayName)", category: .network)
        }
    }

    nonisolated func session(
        _ session: MCSession,
        didFinishReceivingResourceWithName resourceName: String,
        fromPeer peerID: MCPeerID,
        at localURL: URL?,
        withError error: Error?
    ) {
        Task { @MainActor in
            if let error = error {
                log("[RELAY_SESSION] Failed to receive resource: \(error.localizedDescription)", category: .network)
            }
        }
    }
}
