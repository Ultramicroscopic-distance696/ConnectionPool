// ConnectionPoolViewModel.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation
import Combine

/// View model for the Connection Pool app
@MainActor
public final class ConnectionPoolViewModel: ObservableObject, PoolAppLifecycle {

    // MARK: - Published Properties

    /// Current view state
    @Published public var currentView: ConnectionPoolViewState = .home

    /// Pool configuration for hosting
    @Published public var poolName: String = ""
    @Published public var maxPeers: Int = 2
    @Published public var requireEncryption: Bool = true
    @Published public var autoAcceptPeers: Bool = false

    /// User profile settings
    @Published public var showProfileSettings: Bool = false
    @Published public var editingProfileName: String = ""
    @Published public var editingProfileEmoji: String = ""
    @Published public var editingProfileColorIndex: Int = 0

    /// Chat messages (kept for backward compatibility)
    @Published public var chatMessages: [ChatMessage] = []
    @Published public var chatInput: String = ""

    /// Pending invitations list (for host)
    @Published public var pendingInvitations: [DiscoveredPeer] = []

    /// Current invitation being shown in sheet
    @Published public var currentInvitation: DiscoveredPeer?
    @Published public var showInvitationSheet: Bool = false

    /// Pool join code entry - uses ZStack overlay approach for reliability
    /// The overlay is shown when both showJoinCodeOverlay is true AND pendingJoinPeer is set
    @Published public var showJoinCodeOverlay: Bool = false
    @Published public var joinCodeInput: String = ""
    @Published public var pendingJoinPeer: DiscoveredPeer?

    /// Blocked devices
    @Published public var blockedDevices: [BlockedDevice] = []
    @Published public var showBlockedDevicesSheet: Bool = false

    /// Error handling
    @Published public var errorMessage: String?
    @Published public var showError: Bool = false

    /// Callback for opening Pool Chat app
    public var onOpenPoolChat: (() -> Void)?

    /// Callback for opening a game
    public var onOpenGame: ((MultiplayerGameType) -> Void)?

    // MARK: - Connection Pool Manager

    /// Uses the shared singleton to ensure connection survives window close/reopen cycles
    public let poolManager = ConnectionPoolManager.shared

    // MARK: - Observed Pool Manager State
    // These mirror poolManager's published properties to ensure SwiftUI observes changes
    // SwiftUI does not automatically observe nested @ObservableObject @Published properties

    @Published public private(set) var poolState: PoolState = .idle
    @Published public private(set) var discoveredPeers: [DiscoveredPeer] = []
    @Published public private(set) var connectedPeers: [Peer] = []
    @Published public private(set) var currentSession: PoolSession?
    @Published public private(set) var isHost: Bool = false

    // MARK: - Private Properties

    private var cancellables = Set<AnyCancellable>()

    // MARK: - PoolAppLifecycle

    @Published public private(set) var runtimeState: PoolAppState = .active

    // MARK: - Initialization

    public init() {
        setupSubscriptions()
        setupDefaultPoolName()
        initializeProfileEditing()

        // Share pool manager with MultiplayerGameService singleton
        // This ensures games can detect pool connection and send multiplayer messages
        MultiplayerGameService.shared.setPoolManager(poolManager)

        // Sync initial state from the shared pool manager (in case connection was established before)
        syncInitialStateFromPoolManager()
    }

    /// Sync the ViewModel's published state with the shared pool manager's current state
    /// This handles the case where the window was closed and reopened while connected
    private func syncInitialStateFromPoolManager() {
        poolState = poolManager.poolState
        discoveredPeers = poolManager.discoveredPeers
        connectedPeers = poolManager.connectedPeers
        currentSession = poolManager.currentSession
        isHost = poolManager.isHost
        blockedDevices = poolManager.blockedDevices

        // Set the view to lobby if already connected
        if poolState == .hosting || poolState == .connected {
            currentView = .lobby
        }
    }

    private func setupDefaultPoolName() {
        poolName = "\(poolManager.localProfile.displayName)'s Pool"
    }

    private func initializeProfileEditing() {
        let profile = poolManager.localProfile
        editingProfileName = profile.displayName
        editingProfileEmoji = profile.avatarEmoji
        editingProfileColorIndex = profile.avatarColorIndex
    }

    /// Current user profile
    public var localProfile: PoolUserProfile {
        poolManager.localProfile
    }

    /// Start editing profile
    public func startEditingProfile() {
        editingProfileName = poolManager.localProfile.displayName
        editingProfileEmoji = poolManager.localProfile.avatarEmoji
        editingProfileColorIndex = poolManager.localProfile.avatarColorIndex
        showProfileSettings = true
    }

    /// Save profile changes
    public func saveProfile() {
        let name = editingProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            showError(message: "Display name cannot be empty")
            return
        }

        let profile = PoolUserProfile(
            displayName: name,
            avatarEmoji: editingProfileEmoji,
            avatarColorIndex: editingProfileColorIndex
        )
        poolManager.updateProfile(profile)

        // Update pool name if it was using the default
        if poolName.hasSuffix("'s Pool") {
            poolName = "\(name)'s Pool"
        }

        showProfileSettings = false
    }

    /// Cancel profile editing
    public func cancelProfileEditing() {
        initializeProfileEditing()
        showProfileSettings = false
    }

    private func setupSubscriptions() {
        // Subscribe to pool state changes and mirror to our published property
        poolManager.$poolState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.poolState = state
                self?.handlePoolStateChange(state)
            }
            .store(in: &cancellables)

        // Subscribe to discovered peers and mirror to our published property
        poolManager.$discoveredPeers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] peers in
                self?.discoveredPeers = peers
            }
            .store(in: &cancellables)

        // Subscribe to connected peers and mirror to our published property
        poolManager.$connectedPeers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] peers in
                self?.connectedPeers = peers
            }
            .store(in: &cancellables)

        // Subscribe to current session and mirror to our published property
        poolManager.$currentSession
            .receive(on: DispatchQueue.main)
            .sink { [weak self] session in
                self?.currentSession = session
            }
            .store(in: &cancellables)

        // Subscribe to isHost and mirror to our published property
        poolManager.$isHost
            .receive(on: DispatchQueue.main)
            .sink { [weak self] host in
                self?.isHost = host
            }
            .store(in: &cancellables)

        // Subscribe to received messages
        poolManager.messageReceived
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.handleReceivedMessage(message)
            }
            .store(in: &cancellables)

        // Subscribe to peer events
        poolManager.peerEvent
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handlePeerEvent(event)
            }
            .store(in: &cancellables)
    }

    // MARK: - PoolAppLifecycle Protocol

    public func activate() {
        runtimeState = .active
        log("ConnectionPool activated", category: .runtime)
    }

    public func moveToBackground() {
        runtimeState = .background
        log("ConnectionPool moved to background", category: .runtime)
    }

    public func suspend() {
        // Don't suspend if there's an active connection - the pool should keep running
        // to maintain connectivity with peers. This prevents the connection from being
        // disrupted when the user switches to another app window.
        let currentPoolState = poolManager.poolState
        if currentPoolState == .connected || currentPoolState == .hosting {
            log("ConnectionPool suspend skipped - active connection (\(currentPoolState))", category: .runtime)
            // Keep state as background instead of suspended to allow continued operation
            runtimeState = .background
            return
        }

        runtimeState = .suspended
        log("ConnectionPool suspended", category: .runtime)
    }

    public func terminate() {
        runtimeState = .terminated
        // NOTE: We intentionally do NOT disconnect when the window closes.
        // The pool connection should persist until the user explicitly disconnects
        // via the "Close Pool" / "Leave Pool" button, or the app is fully terminated.
        // poolManager.disconnect() is NOT called here.
        cancellables.removeAll()
        log("ConnectionPool terminated (connection kept alive)", category: .runtime)
    }

    /// Explicitly disconnect from the pool. Call this when user wants to leave.
    public func explicitDisconnect() {
        poolManager.disconnect()
        currentView = .home
        chatMessages = []
        pendingInvitations = []
        log("ConnectionPool explicitly disconnected by user", category: .runtime)
    }

    // MARK: - Public Actions

    /// Start hosting a new pool
    public func startHosting() {
        guard !poolName.isEmpty else {
            showError(message: "Please enter a pool name")
            return
        }

        let config = PoolConfiguration(
            name: poolName,
            maxPeers: maxPeers,
            requireEncryption: requireEncryption,
            autoAcceptInvitations: autoAcceptPeers,
            generatePoolCode: true
        )

        poolManager.startHosting(configuration: config)
        currentView = .lobby
    }

    /// Start browsing for pools
    public func startBrowsing() {
        poolManager.startBrowsing()
        currentView = .browse
    }

    /// Refresh browsing (restart scanning)
    public func refreshBrowsing() {
        poolManager.disconnect()
        poolManager.startBrowsing()
    }

    /// Join a discovered pool
    public func joinPool(_ peer: DiscoveredPeer) {
        log("joinPool called for peer: \(peer.displayName), hasCode: \(peer.hasPoolCode)", category: .network)

        // If the pool requires a code, prompt the user to enter it via overlay
        if peer.hasPoolCode {
            log("Pool requires code, showing code entry overlay", category: .network)
            pendingJoinPeer = peer
            joinCodeInput = ""
            showJoinCodeOverlay = true
        } else {
            // No code required, join directly
            log("No code required, joining directly", category: .network)
            poolManager.joinPool(peer)
        }
    }

    /// Confirm joining with the entered code.
    /// The code is sent to the host via MC invitation context for server-side validation.
    public func confirmJoinWithCode() {
        guard let peer = pendingJoinPeer else { return }

        let enteredCode = joinCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()

        guard !enteredCode.isEmpty else {
            showError(message: "Please enter a pool code.")
            return
        }

        // SECURITY: Do NOT validate client-side. Send to host for authoritative validation.
        // The host will reject the MC invitation if the code is wrong.
        showJoinCodeOverlay = false
        let peerToJoin = peer
        pendingJoinPeer = nil
        joinCodeInput = ""
        poolManager.joinPool(peerToJoin, poolCode: enteredCode)
    }

    /// Cancel joining a pool
    public func cancelJoin() {
        showJoinCodeOverlay = false
        pendingJoinPeer = nil
        joinCodeInput = ""
    }

    /// Send a chat message
    public func sendChatMessage() {
        guard !chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        poolManager.sendChat(chatInput)
        chatInput = ""
    }

    /// Disconnect from the current pool (user-initiated)
    public func disconnect() {
        poolManager.disconnect()
        currentView = .home
        chatMessages = []
        pendingInvitations = []
        log("ConnectionPool disconnected by user action", category: .runtime)
    }

    /// Accept an invitation
    public func acceptInvitation(_ invitation: DiscoveredPeer) {
        poolManager.acceptInvitation(from: invitation.id)
        pendingInvitations.removeAll { $0.id == invitation.id }

        if currentInvitation?.id == invitation.id {
            currentInvitation = nil
            showInvitationSheet = false
        }
    }

    /// Reject an invitation
    public func rejectInvitation(_ invitation: DiscoveredPeer) {
        poolManager.rejectInvitation(from: invitation.id)
        pendingInvitations.removeAll { $0.id == invitation.id }

        if currentInvitation?.id == invitation.id {
            currentInvitation = nil
            showInvitationSheet = false
        }
    }

    /// Accept pending invitation (backward compatibility)
    public func acceptPendingInvitation() {
        guard let invitation = currentInvitation else { return }
        acceptInvitation(invitation)
    }

    /// Reject pending invitation (backward compatibility)
    public func rejectPendingInvitation() {
        guard let invitation = currentInvitation else { return }
        rejectInvitation(invitation)
    }

    /// Kick a peer from the pool (host only)
    public func kickPeer(_ peer: Peer) {
        // TODO: Implement kick functionality in ConnectionPoolManager
        log("Kicking peer: \(peer.displayName)", category: .network)
    }

    /// Block a connected peer (host only) - also kicks them
    public func blockPeer(_ peer: Peer) {
        poolManager.blockDevice(peer.id, displayName: peer.effectiveDisplayName)
        refreshBlockedDevices()
    }

    /// Block a peer from pending invitations (host only) - also rejects the invitation
    public func blockPendingPeer(_ invitation: DiscoveredPeer) {
        poolManager.blockDevice(invitation.id, displayName: invitation.displayName)
        pendingInvitations.removeAll { $0.id == invitation.id }
        if currentInvitation?.id == invitation.id {
            currentInvitation = nil
            showInvitationSheet = false
        }
        refreshBlockedDevices()
    }

    /// Unblock a device
    public func unblockDevice(_ device: BlockedDevice) {
        poolManager.unblockDevice(device.id)
        refreshBlockedDevices()
    }

    /// Refresh the blocked devices list from the manager
    private func refreshBlockedDevices() {
        blockedDevices = poolManager.blockedDevices
    }

    /// Open Pool Chat app
    public func openPoolChat() {
        onOpenPoolChat?()
    }

    /// Open a multiplayer game
    public func openGame(_ gameType: MultiplayerGameType) {
        onOpenGame?(gameType)
    }

    /// Go back to home view
    public func goBack() {
        switch currentView {
        case .browse:
            poolManager.disconnect()
            currentView = .home
        case .lobby:
            if poolManager.poolState == .idle {
                // Not yet hosting, just go back
                currentView = .home
            } else {
                // Hosting or connected, disconnect
                disconnect()
            }
        case .chat:
            currentView = .lobby
        default:
            currentView = .home
        }
    }

    // MARK: - Private Handlers

    private func handlePoolStateChange(_ state: PoolState) {
        switch state {
        case .connected:
            currentView = .lobby
        case .error(let message):
            showError(message: message)
        default:
            break
        }
    }

    private func handleReceivedMessage(_ message: PoolMessage) {
        switch message.type {
        case .chat:
            if let payload = message.decodePayload(as: ChatPayload.self) {
                let chatMessage = ChatMessage(
                    id: message.id,
                    senderID: message.senderID,
                    senderName: message.senderName,
                    text: payload.text,
                    timestamp: message.timestamp,
                    isFromLocalUser: message.senderID == poolManager.localPeerID
                )
                if !chatMessages.contains(where: { $0.id == chatMessage.id }) {
                    chatMessages.append(chatMessage)
                }
            }

        case .system:
            if let payload = message.decodePayload(as: SystemPayload.self) {
                let systemMessage = ChatMessage(
                    id: message.id,
                    senderID: "system",
                    senderName: "System",
                    text: payload.text,
                    timestamp: message.timestamp,
                    isFromLocalUser: false,
                    isSystemMessage: true
                )
                if !chatMessages.contains(where: { $0.id == systemMessage.id }) {
                    chatMessages.append(systemMessage)
                }
            }

        case .profileUpdate:
            if let payload = message.decodePayload(as: ProfileUpdatePayload.self) {
                poolManager.updatePeerProfile(peerID: payload.peerID, profile: payload.profile)
            }

        default:
            // Handle other message types (game states, etc.)
            break
        }
    }

    private func handlePeerEvent(_ event: PeerEvent) {
        switch event {
        case .connected(let peer):
            let systemMessage = ChatMessage(
                senderID: "system",
                senderName: "System",
                text: "\(peer.displayName) joined the pool",
                isFromLocalUser: false,
                isSystemMessage: true
            )
            if !chatMessages.contains(where: { $0.id == systemMessage.id }) {
                chatMessages.append(systemMessage)
            }

        case .disconnected(let peer):
            let systemMessage = ChatMessage(
                senderID: "system",
                senderName: "System",
                text: "\(peer.displayName) left the pool",
                isFromLocalUser: false,
                isSystemMessage: true
            )
            if !chatMessages.contains(where: { $0.id == systemMessage.id }) {
                chatMessages.append(systemMessage)
            }

        case .invitationReceived(let peer):
            // Add to pending invitations list
            if !pendingInvitations.contains(where: { $0.id == peer.id }) {
                pendingInvitations.append(peer)
            }

            // If auto-accept is disabled and we're not showing a sheet, show it
            if !autoAcceptPeers && currentInvitation == nil {
                currentInvitation = peer
                showInvitationSheet = true
            }

        case .invitationRejectedBlocked(let name):
            log("Rejected invitation from blocked device: \(name)", category: .network)

        case .deviceAutoBlocked(let name):
            refreshBlockedDevices()
            log("Device auto-blocked after repeated failed attempts: \(name)", category: .network)
        }
    }

    private func showError(message: String) {
        errorMessage = message
        showError = true
    }
}

// MARK: - View States

public enum ConnectionPoolViewState: Equatable {
    case home
    case browse
    case lobby
    case chat
}

// MARK: - Chat Message Model

public struct ChatMessage: Identifiable, Equatable {
    public let id: UUID
    public let senderID: String
    public let senderName: String
    public let text: String
    public let timestamp: Date
    public let isFromLocalUser: Bool
    public var isSystemMessage: Bool

    public init(
        id: UUID = UUID(),
        senderID: String,
        senderName: String,
        text: String,
        timestamp: Date = Date(),
        isFromLocalUser: Bool,
        isSystemMessage: Bool = false
    ) {
        self.id = id
        self.senderID = senderID
        self.senderName = senderName
        self.text = text
        self.timestamp = timestamp
        self.isFromLocalUser = isFromLocalUser
        self.isSystemMessage = isSystemMessage
    }

    /// Avatar color index based on sender ID
    public var avatarColorIndex: Int {
        abs(senderID.hashValue) % 8
    }
}
