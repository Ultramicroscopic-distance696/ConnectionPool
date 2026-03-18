// BlockedDevice.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation

/// Reason a device was blocked
public enum BlockReason: String, Codable, Sendable {
    /// Host manually blocked the device
    case manual
    /// Device was auto-blocked after too many failed join attempts
    case bruteForce
}

/// Represents a device that has been blocked from joining the pool
public struct BlockedDevice: Identifiable, Codable, Sendable {
    public let id: String
    public let peerDisplayName: String
    public let blockedAt: Date
    public let reason: BlockReason

    public init(
        id: String,
        peerDisplayName: String,
        blockedAt: Date = Date(),
        reason: BlockReason
    ) {
        self.id = id
        self.peerDisplayName = peerDisplayName
        self.blockedAt = blockedAt
        self.reason = reason
    }
}
