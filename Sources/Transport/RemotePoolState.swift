// RemotePoolState.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app
//
// Persists remote pool connection state across app restarts.

import Foundation

/// Saved state for a remote pool connection.
/// Persisted via the configured secure storage provider (or UserDefaults
/// when no provider is set) so the app can auto-reconnect on launch.
public struct RemotePoolState: Codable, Sendable {
    /// The relay server URL (e.g., "ws://localhost:9090").
    public var serverURL: String

    /// The pool name.
    public var poolName: String

    /// Whether this server has been claimed by this device.
    public var isClaimed: Bool

    /// The pool ID used for this session.
    public var poolID: UUID

    /// Max peers for the pool.
    public var maxPeers: Int

    /// Whether this device is the host.
    public var isHost: Bool

    /// When this state was last saved.
    public var lastConnected: Date

    public init(
        serverURL: String,
        poolName: String,
        isClaimed: Bool,
        poolID: UUID,
        maxPeers: Int,
        isHost: Bool
    ) {
        self.serverURL = serverURL
        self.poolName = poolName
        self.isClaimed = isClaimed
        self.poolID = poolID
        self.maxPeers = maxPeers
        self.isHost = isHost
        self.lastConnected = Date()
    }

    // MARK: - Persistence

    private static let storageKey = "remote_pool_state"

    /// Returns the secure storage provider if configured, otherwise `nil`.
    /// Must be accessed from `@MainActor` since the configuration property is `@MainActor`-isolated.
    @MainActor
    private static var secureProvider: BlockListStorageProvider? {
        ConnectionPoolConfiguration.remotePoolStateStorageProvider
    }

    /// Save state, using the secure storage provider when available,
    /// falling back to UserDefaults when no provider is configured.
    @MainActor
    public func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }

        if let provider = Self.secureProvider {
            try? provider.save(data, forKey: Self.storageKey)
        } else {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    /// Load state, using the secure storage provider when available,
    /// falling back to UserDefaults when no provider is configured.
    @MainActor
    public static func load() -> RemotePoolState? {
        if let provider = secureProvider {
            guard let data = try? provider.load(forKey: storageKey),
                  let state = try? JSONDecoder().decode(RemotePoolState.self, from: data) else {
                return nil
            }
            return state
        }

        // No secure provider — use UserDefaults
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let state = try? JSONDecoder().decode(RemotePoolState.self, from: data) else {
            return nil
        }
        return state
    }

    /// Clear saved state.
    @MainActor
    public static func clear() {
        if let provider = secureProvider {
            try? provider.save(Data(), forKey: storageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: storageKey)
        }
    }
}
