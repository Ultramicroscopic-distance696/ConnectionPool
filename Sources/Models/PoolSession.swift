// PoolSession.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation

/// Represents a connection pool session
public struct PoolSession: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let hostPeerID: String
    public let createdAt: Date
    public var peers: [Peer]
    public var maxPeers: Int
    public var isEncrypted: Bool
    public internal(set) var poolCode: String?

    /// Whether this device is the host of the session
    public var isHost: Bool {
        // Will be set based on local peer ID comparison
        false
    }

    /// Number of connected peers (excluding host)
    public var connectedPeersCount: Int {
        peers.filter { $0.status == .connected && !$0.isHost }.count
    }

    /// Whether the session can accept more peers
    public var canAcceptMorePeers: Bool {
        connectedPeersCount < maxPeers - 1 // -1 for host
    }

    public init(
        id: UUID = UUID(),
        name: String,
        hostPeerID: String,
        createdAt: Date = Date(),
        peers: [Peer] = [],
        maxPeers: Int = 8,
        isEncrypted: Bool = true,
        poolCode: String? = nil
    ) {
        self.id = id
        self.name = name
        self.hostPeerID = hostPeerID
        self.createdAt = createdAt
        self.peers = peers
        self.maxPeers = maxPeers
        self.isEncrypted = isEncrypted
        self.poolCode = poolCode
    }
}

/// Configuration for creating a new pool
public struct PoolConfiguration: Sendable {
    public var name: String
    public var maxPeers: Int
    public var requireEncryption: Bool
    public var autoAcceptInvitations: Bool
    public var generatePoolCode: Bool

    public static let `default` = PoolConfiguration(
        name: "My Pool",
        maxPeers: 8,
        requireEncryption: true,
        autoAcceptInvitations: false,
        generatePoolCode: true
    )

    public init(
        name: String,
        maxPeers: Int = 8,
        requireEncryption: Bool = true,
        autoAcceptInvitations: Bool = false,
        generatePoolCode: Bool = true
    ) {
        self.name = name
        self.maxPeers = maxPeers
        self.requireEncryption = requireEncryption
        self.autoAcceptInvitations = autoAcceptInvitations
        self.generatePoolCode = generatePoolCode
    }
}

/// State of the connection pool
public enum PoolState: Equatable, Sendable {
    case idle
    case hosting
    case browsing
    case connecting
    case connected
    case error(String)

    public var displayText: String {
        switch self {
        case .idle: return "Not Connected"
        case .hosting: return "Hosting Pool"
        case .browsing: return "Looking for Pools"
        case .connecting: return "Connecting..."
        case .connected: return "Connected"
        case .error(let message): return "Error: \(message)"
        }
    }

    public var isActive: Bool {
        switch self {
        case .hosting, .browsing, .connecting, .connected:
            return true
        case .idle, .error:
            return false
        }
    }
}
