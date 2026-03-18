// MeshTopology.swift
// ConnectionPool
//
// Created by Olib AI (www.olib.ai)
// StealthOS - stealthos.app

import Foundation

/// Represents the known topology of the mesh network.
///
/// SAFETY: @unchecked Sendable is required because:
/// 1. The class maintains mutable topology state (neighbor maps, timestamps)
/// 2. It may be accessed from multiple actors/tasks during mesh routing operations
/// 3. All mutable state is protected by NSLock for thread-safe access
/// 4. The lock guards: neighborMap, lastHeard dictionaries
///
/// Alternative considered: Converting to an actor would require all callers to use await,
/// which would complicate synchronous routing decisions. The lock-based approach maintains
/// synchronous access patterns while ensuring thread safety.
public final class MeshTopology: @unchecked Sendable {
    
    // MARK: - Properties
    
    /// Lock for thread-safe access to mutable state
    private let lock = NSLock()
    
    /// Map of peer ID to their known direct neighbors (protected by lock)
    private var _neighborMap: [String: Set<String>] = [:]
    
    /// Timestamps for when we last heard from each peer (protected by lock)
    private var _lastHeard: [String: Date] = [:]
    
    /// Our local peer ID
    public let localPeerID: String
    
    /// Stale peer threshold in seconds (peers not heard from in this time are considered stale)
    private let staleThreshold: TimeInterval = 60.0
    
    // MARK: - Thread-Safe Accessors
    
    private var neighborMap: [String: Set<String>] {
        get { lock.withLock { _neighborMap } }
        set { lock.withLock { _neighborMap = newValue } }
    }
    
    private var lastHeard: [String: Date] {
        get { lock.withLock { _lastHeard } }
        set { lock.withLock { _lastHeard = newValue } }
    }
    
    // MARK: - Initialization
    
    /// Creates a new mesh topology tracker.
    /// - Parameter localPeerID: The ID of the local peer in the mesh network.
    public init(localPeerID: String) {
        self.localPeerID = localPeerID
        // Initialize our own entry with empty neighbors
        _neighborMap[localPeerID] = []
        _lastHeard[localPeerID] = Date()
    }
    
    // MARK: - Topology Updates
    
    /// Updates the topology with a peer's direct neighbors.
    ///
    /// This method should be called when receiving topology broadcast messages
    /// from other peers in the mesh network.
    ///
    /// - Parameters:
    ///   - peerID: The peer whose neighbors are being updated.
    ///   - neighbors: The set of peer IDs that are direct neighbors of the specified peer.
    public func updateNeighbors(for peerID: String, neighbors: Set<String>) {
        lock.withLock {
            _neighborMap[peerID] = neighbors
            _lastHeard[peerID] = Date()
        }
    }
    
    /// Gets the known direct neighbors for a peer.
    /// - Parameter peerID: The peer to query neighbors for.
    /// - Returns: A set of peer IDs that are direct neighbors, or empty set if unknown.
    public func neighbors(for peerID: String) -> Set<String> {
        lock.withLock { _neighborMap[peerID] ?? [] }
    }
    
    /// Checks if we can reach a peer directly (they are our direct neighbor).
    /// - Parameter peerID: The peer to check reachability for.
    /// - Returns: `true` if the peer is a direct neighbor of the local peer.
    public func canReachDirectly(_ peerID: String) -> Bool {
        lock.withLock { _neighborMap[localPeerID]?.contains(peerID) ?? false }
    }
    
    // MARK: - Path Finding
    
    /// Finds the shortest path to a destination peer using BFS.
    ///
    /// The returned path represents the sequence of peers to route through,
    /// excluding the local peer but including the destination.
    ///
    /// - Parameter destinationPeerID: The peer to find a path to.
    /// - Returns: An array of peer IDs representing the path, or `nil` if unreachable.
    ///
    /// - Example:
    ///   If local peer is "A", and the shortest path to "D" goes through "B" then "C",
    ///   this method returns `["B", "C", "D"]`.
    public func findPath(to destinationPeerID: String) -> [String]? {
        // Handle edge case: destination is self
        guard destinationPeerID != localPeerID else { return [] }
        
        // Snapshot the neighbor map to avoid holding lock during BFS
        let snapshot: [String: Set<String>] = lock.withLock { _neighborMap }
        
        // BFS setup
        var queue: [(peerID: String, path: [String])] = []
        var visited: Set<String> = [localPeerID]
        
        // Start from local peer's direct neighbors
        guard let localNeighbors = snapshot[localPeerID] else { return nil }
        
        for neighbor in localNeighbors {
            if neighbor == destinationPeerID {
                // Direct neighbor is the destination
                return [destinationPeerID]
            }
            queue.append((peerID: neighbor, path: [neighbor]))
            visited.insert(neighbor)
        }
        
        // BFS traversal
        var queueIndex = 0
        while queueIndex < queue.count {
            let (currentPeerID, currentPath) = queue[queueIndex]
            queueIndex += 1
            
            // Get neighbors of current peer
            guard let currentNeighbors = snapshot[currentPeerID] else { continue }
            
            for nextPeer in currentNeighbors {
                guard !visited.contains(nextPeer) else { continue }
                
                let newPath = currentPath + [nextPeer]
                
                if nextPeer == destinationPeerID {
                    // Found the destination
                    return newPath
                }
                
                visited.insert(nextPeer)
                queue.append((peerID: nextPeer, path: newPath))
            }
        }
        
        // No path found
        return nil
    }
    
    // MARK: - Peer Discovery
    
    /// All known peers in the mesh network.
    ///
    /// This includes both directly connected peers and peers known through
    /// topology broadcasts from other nodes.
    public var allKnownPeers: Set<String> {
        lock.withLock {
            var peers = Set(_neighborMap.keys)
            // Also include all peers mentioned as neighbors
            for neighbors in _neighborMap.values {
                peers.formUnion(neighbors)
            }
            return peers
        }
    }
    
    /// Our direct neighbors in the mesh network.
    public var directNeighbors: Set<String> {
        lock.withLock { _neighborMap[localPeerID] ?? [] }
    }
    
    // MARK: - Peer Management
    
    /// Removes stale peers that have not been heard from recently.
    ///
    /// Peers are considered stale if more than 60 seconds have elapsed
    /// since their last topology update was received.
    public func pruneStale() {
        let cutoff = Date().addingTimeInterval(-staleThreshold)
        
        lock.withLock {
            // Find stale peer IDs
            let stalePeers = _lastHeard.filter { $0.value < cutoff }.map { $0.key }
            
            // Don't prune ourselves
            let peersToRemove = stalePeers.filter { $0 != localPeerID }
            
            // Remove stale peers from all data structures
            for peerID in peersToRemove {
                _neighborMap.removeValue(forKey: peerID)
                _lastHeard.removeValue(forKey: peerID)
            }
            
            // Also remove stale peers from neighbor sets of remaining peers
            for (peerID, neighbors) in _neighborMap {
                _neighborMap[peerID] = neighbors.subtracting(peersToRemove)
            }
        }
    }
    
    /// Removes a peer from the topology.
    ///
    /// This should be called when a peer explicitly disconnects from the network.
    ///
    /// - Parameter peerID: The peer to remove from the topology.
    public func removePeer(_ peerID: String) {
        // Don't allow removing self
        guard peerID != localPeerID else { return }
        
        lock.withLock {
            // Remove peer's own entry
            _neighborMap.removeValue(forKey: peerID)
            _lastHeard.removeValue(forKey: peerID)
            
            // Remove peer from all neighbor sets
            for (existingPeerID, neighbors) in _neighborMap {
                _neighborMap[existingPeerID] = neighbors.subtracting([peerID])
            }
        }
    }
    
    /// Adds a direct connection to a peer.
    ///
    /// This should be called when a new direct connection is established
    /// with another peer in the mesh network.
    ///
    /// - Parameter peerID: The peer that we are now directly connected to.
    public func addDirectConnection(_ peerID: String) {
        lock.withLock {
            // Add peer to our neighbors
            var localNeighbors = _neighborMap[localPeerID] ?? []
            localNeighbors.insert(peerID)
            _neighborMap[localPeerID] = localNeighbors
            
            // Ensure peer has an entry (even if we don't know their neighbors yet)
            if _neighborMap[peerID] == nil {
                _neighborMap[peerID] = []
            }
            
            // Update timestamps
            _lastHeard[localPeerID] = Date()
            _lastHeard[peerID] = Date()
        }
    }
}

// MARK: - Topology Broadcast Message

/// Payload for topology broadcast messages.
///
/// This structure is used to share a peer's direct neighbor information
/// with other peers in the mesh network, enabling distributed topology awareness.
public struct TopologyBroadcast: Codable, Sendable {
    /// The peer ID that is broadcasting its topology.
    public let peerID: String
    
    /// The direct neighbors of the broadcasting peer.
    public let directNeighbors: [String]
    
    /// Timestamp when this broadcast was created.
    public let timestamp: Date
    
    /// Creates a new topology broadcast message.
    /// - Parameters:
    ///   - peerID: The ID of the peer broadcasting its topology.
    ///   - directNeighbors: Array of peer IDs that are direct neighbors.
    ///   - timestamp: The time of the broadcast (defaults to now).
    public init(peerID: String, directNeighbors: [String], timestamp: Date = Date()) {
        self.peerID = peerID
        self.directNeighbors = directNeighbors
        self.timestamp = timestamp
    }
}
