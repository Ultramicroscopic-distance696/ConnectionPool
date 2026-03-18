// UncheckedSendableBox.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation

// MARK: - UncheckedSendableBox

/// A wrapper that allows passing non-Sendable values across concurrency boundaries
/// when the developer can guarantee safety.
///
/// SAFETY: @unchecked Sendable is the entire purpose of this type. It is a deliberate
/// escape hatch for situations where the developer can guarantee thread safety but
/// the compiler cannot verify it. Use with caution.
///
/// Only use when:
/// - The wrapped value is accessed from a single actor/thread
/// - The value is read-only after crossing the boundary
/// - The value's type is inherently thread-safe but not marked Sendable
public struct UncheckedSendableBox<T>: @unchecked Sendable {
    public let value: T

    public init(_ value: T) {
        self.value = value
    }
}
