// ConnectionPoolConfiguration.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation

/// Protocol for pluggable block list storage.
///
/// Implement this protocol to provide encrypted or otherwise secure persistence
/// for the device block list. If no provider is configured on
/// `ConnectionPoolConfiguration`, `DeviceBlockListService` falls back to plain
/// `UserDefaults`.
public protocol BlockListStorageProvider: Sendable {
    /// Persist raw data for the given key.
    func save(_ data: Data, forKey key: String) throws
    /// Load previously persisted data for the given key, or `nil` if none exists.
    func load(forKey key: String) throws -> Data?
}

/// Static configuration point for the ConnectionPool package.
///
/// The host app should call `ConnectionPoolConfiguration.logger = ...` at startup
/// to inject its logging infrastructure. If not configured, a default `os.Logger`
/// fallback is used.
public enum ConnectionPoolConfiguration {
    /// Logger instance injected by the host app.
    /// Set this before any ConnectionPool APIs are used.
    private static let _loggerLock = NSLock()
    nonisolated(unsafe) private static var _logger: ConnectionPoolLogger?
    public static var logger: ConnectionPoolLogger? {
        get { _loggerLock.withLock { _logger } }
        set { _loggerLock.withLock { _logger = newValue } }
    }

    /// Optional secure storage provider for the device block list.
    ///
    /// When set, `DeviceBlockListService` persists block list data through this
    /// provider instead of plain `UserDefaults`. The host app should wire this to
    /// an encrypted storage backend (e.g., Keychain or SecureDataStore).
    ///
    /// Set this at app startup alongside the logger, before any ConnectionPool
    /// APIs are used.
    @MainActor public static var blockListStorageProvider: BlockListStorageProvider?

    /// Optional secure storage provider for remote pool connection state.
    ///
    /// When set, `RemotePoolState` persists through this provider instead of
    /// plain `UserDefaults`. The host app should wire this to an encrypted
    /// storage backend (e.g., Keychain or SecureDataStore) to prevent leaking
    /// connection history (server URL, pool ID, host status).
    ///
    /// Set this at app startup alongside the logger, before any ConnectionPool
    /// APIs are used.
    @MainActor public static var remotePoolStateStorageProvider: (any BlockListStorageProvider)?
}
