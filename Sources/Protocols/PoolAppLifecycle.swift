// PoolAppLifecycle.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation

// MARK: - App State

/// Represents the runtime state of a ConnectionPool-based app
@available(macOS 14.0, iOS 17.0, *)
public enum PoolAppState: String, Sendable {
    /// App is not running, no resources allocated
    case terminated
    /// App is running in background, reduced resources
    case suspended
    /// App is running and visible but not focused
    case background
    /// App is running, visible, and focused (active)
    case active
}

// MARK: - Pool App Lifecycle Protocol

/// Protocol for managing the runtime lifecycle of ConnectionPool views.
///
/// This mirrors the host app's `AppRuntimeManaged` protocol so that
/// `ConnectionPoolViewModel` can participate in the app's lifecycle
/// management without depending on the Core package.
@available(macOS 14.0, iOS 17.0, *)
@MainActor
public protocol PoolAppLifecycle: AnyObject {
    /// Current runtime state of the app
    var runtimeState: PoolAppState { get }

    /// Called when app should transition to active state (focused and visible)
    /// Resume all operations, start timers, enable animations
    func activate()

    /// Called when app is visible but not focused
    /// Continue showing content but reduce update frequency
    func moveToBackground()

    /// Called when app is minimized or hidden
    /// Pause expensive operations, stop timers, free temporary resources
    func suspend()

    /// Called when app is being closed
    /// Clean up all resources, cancel network requests, save state
    func terminate()

    /// Memory pressure notification - free as much memory as possible
    func handleMemoryWarning()
}

// MARK: - Default Implementation

@available(macOS 14.0, iOS 17.0, *)
public extension PoolAppLifecycle {
    func activate() {}
    func moveToBackground() {}
    func suspend() {}
    func terminate() {}
    func handleMemoryWarning() {}
}
