// MeshRelayServiceTests.swift
// ConnectionPoolTests

import XCTest
import CryptoKit
import Combine
@testable import ConnectionPool

// MARK: - RelayEnvelope HMAC Tests

final class RelayEnvelopeHMACTests: XCTestCase {

    // MARK: - Helpers

    private func makeKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    private func makeEnvelope(
        messageID: UUID = UUID(),
        originPeerID: String = "origin",
        destinationPeerID: String? = "dest",
        ttl: Int = RelayEnvelope.defaultTTL,
        hopPath: [String] = [],
        payload: Data = Data("test".utf8),
        poolID: UUID = UUID(),
        timestamp: Date = Date()
    ) -> RelayEnvelope {
        RelayEnvelope(
            messageID: messageID,
            originPeerID: originPeerID,
            destinationPeerID: destinationPeerID,
            ttl: ttl,
            hopPath: hopPath,
            encryptedPayload: payload,
            poolID: poolID,
            timestamp: timestamp
        )
    }

    // MARK: - HMAC Verification

    func testRelayEnvelopeHMACVerification() {
        let key = makeKey()
        let poolID = UUID()
        let hmacKey = RelayEnvelope.deriveHMACKey(from: key, poolID: poolID)
        let envelope = makeEnvelope(poolID: poolID).withHMAC(using: hmacKey)

        XCTAssertTrue(envelope.hasHMAC, "Envelope should have HMAC after withHMAC")
        XCTAssertTrue(envelope.verifyHMAC(using: hmacKey), "HMAC must verify with the same key")
    }

    func testRelayEnvelopeHMACRejectsTamperedOrigin() {
        let key = makeKey()
        let poolID = UUID()
        let hmacKey = RelayEnvelope.deriveHMACKey(from: key, poolID: poolID)
        let msgID = UUID()
        let ts = Date()

        // Create and sign with original origin
        let signed = makeEnvelope(
            messageID: msgID,
            originPeerID: "original-origin",
            poolID: poolID,
            timestamp: ts
        ).withHMAC(using: hmacKey)

        // Recreate with tampered origin but copy the HMAC
        let tampered = RelayEnvelope(
            messageID: msgID,
            originPeerID: "tampered-origin",
            destinationPeerID: "dest",
            encryptedPayload: Data("test".utf8),
            poolID: poolID,
            timestamp: ts,
            envelopeHMAC: signed.envelopeHMAC
        )

        XCTAssertFalse(tampered.verifyHMAC(using: hmacKey),
                        "HMAC must reject tampered originPeerID")
    }

    func testRelayEnvelopeHMACRejectsTamperedDestination() {
        let key = makeKey()
        let poolID = UUID()
        let hmacKey = RelayEnvelope.deriveHMACKey(from: key, poolID: poolID)
        let msgID = UUID()
        let ts = Date()

        let signed = makeEnvelope(
            messageID: msgID,
            destinationPeerID: "real-dest",
            poolID: poolID,
            timestamp: ts
        ).withHMAC(using: hmacKey)

        let tampered = RelayEnvelope(
            messageID: msgID,
            originPeerID: "origin",
            destinationPeerID: "fake-dest",
            encryptedPayload: Data("test".utf8),
            poolID: poolID,
            timestamp: ts,
            envelopeHMAC: signed.envelopeHMAC
        )

        XCTAssertFalse(tampered.verifyHMAC(using: hmacKey),
                        "HMAC must reject tampered destinationPeerID")
    }

    func testRelayEnvelopeHMACRejectsTamperedPoolID() {
        let key = makeKey()
        let poolID = UUID()
        let otherPoolID = UUID()
        let hmacKey = RelayEnvelope.deriveHMACKey(from: key, poolID: poolID)
        let msgID = UUID()
        let ts = Date()

        let signed = makeEnvelope(
            messageID: msgID,
            poolID: poolID,
            timestamp: ts
        ).withHMAC(using: hmacKey)

        // The HMAC key is derived per-pool, but even if we use the same hmacKey,
        // the poolID is included in the HMAC input. Recreate with different poolID.
        let tampered = RelayEnvelope(
            messageID: msgID,
            originPeerID: "origin",
            destinationPeerID: "dest",
            encryptedPayload: Data("test".utf8),
            poolID: otherPoolID,
            timestamp: ts,
            envelopeHMAC: signed.envelopeHMAC
        )

        XCTAssertFalse(tampered.verifyHMAC(using: hmacKey),
                        "HMAC must reject tampered poolID")
    }

    // MARK: - Forwarding

    func testRelayEnvelopeForwardingDecrementsTTL() {
        let env = makeEnvelope(ttl: 4, hopPath: ["origin"])
        let fwd = env.forwarded(by: "relay-A")
        XCTAssertNotNil(fwd)
        XCTAssertEqual(fwd?.ttl, 3, "Forwarding must decrement TTL by 1")
    }

    func testRelayEnvelopeForwardingAppendsToHopPath() {
        let env = makeEnvelope(ttl: 4, hopPath: ["origin"])
        let fwd = env.forwarded(by: "relay-A")
        XCTAssertNotNil(fwd)
        XCTAssertEqual(fwd?.hopPath, ["origin", "relay-A"],
                        "Forwarding must append the forwarder to the hop path")
    }

    func testRelayEnvelopeForwardingReturnsNilAtTTLOne() {
        let env = makeEnvelope(ttl: 1)
        let fwd = env.forwarded(by: "relay-A")
        XCTAssertNil(fwd, "forwarded(by:) must return nil when TTL is 1 (would become 0)")
    }

    func testRelayEnvelopeRejectsLoopInHopPath() {
        // Hop path already contains maxTTL+1 entries, so forwarding would exceed the cap
        let env = makeEnvelope(ttl: 5, hopPath: ["a", "b", "c", "d", "e", "f"])
        let fwd = env.forwarded(by: "g")
        XCTAssertNil(fwd, "forwarded(by:) must return nil when hop path would exceed maxTTL+1")
    }

    func testRelayEnvelopePreservesHMACAfterForwarding() {
        let key = makeKey()
        let poolID = UUID()
        let hmacKey = RelayEnvelope.deriveHMACKey(from: key, poolID: poolID)

        let env = makeEnvelope(ttl: 5, hopPath: ["origin"], poolID: poolID)
            .withHMAC(using: hmacKey)
        let fwd = env.forwarded(by: "relay-A")

        XCTAssertNotNil(fwd)
        XCTAssertNotNil(fwd?.envelopeHMAC, "HMAC must be preserved after forwarding")
        XCTAssertEqual(fwd?.envelopeHMAC, env.envelopeHMAC,
                        "HMAC bytes must be identical after forwarding")
        XCTAssertTrue(fwd!.verifyHMAC(using: hmacKey),
                       "HMAC must still verify after forwarding (TTL change)")
    }
}

// MARK: - MeshRelayService Unit Tests

@MainActor
final class MeshRelayServiceUnitTests: XCTestCase {

    // MARK: - Helpers

    private func makeService(localPeerID: String = "local") -> MeshRelayService {
        MeshRelayService(localPeerID: localPeerID)
    }

    private func makeKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    private func makeEnvelope(
        messageID: UUID = UUID(),
        originPeerID: String = "origin",
        destinationPeerID: String? = "local",
        ttl: Int = RelayEnvelope.defaultTTL,
        hopPath: [String] = [],
        payload: Data = Data("test".utf8),
        poolID: UUID = UUID(),
        timestamp: Date = Date(),
        hmacKey: SymmetricKey? = nil
    ) -> RelayEnvelope {
        var env = RelayEnvelope(
            messageID: messageID,
            originPeerID: originPeerID,
            destinationPeerID: destinationPeerID,
            ttl: ttl,
            hopPath: hopPath,
            encryptedPayload: payload,
            poolID: poolID,
            timestamp: timestamp
        )
        if let key = hmacKey {
            env = env.withHMAC(using: key)
        }
        return env
    }

    // MARK: - Topology: Peer Connect / Disconnect

    func testPeerConnectedUpdatesTopology() {
        let service = makeService()
        service.peerConnected("peer-A")

        let topology = service.meshTopology
        XCTAssertTrue(topology.directNeighbors.contains("peer-A"),
                       "After peerConnected, topology must list the peer as a direct neighbor")
    }

    func testPeerDisconnectedUpdatesTopology() {
        let service = makeService()
        service.peerConnected("peer-A")
        XCTAssertTrue(service.meshTopology.directNeighbors.contains("peer-A"))

        service.peerDisconnected("peer-A")
        XCTAssertFalse(service.meshTopology.directNeighbors.contains("peer-A"),
                        "After peerDisconnected, topology must no longer list the peer")
    }

    // MARK: - Deduplication

    func testDeduplicationCachePreventsDuplicateProcessing() {
        let service = makeService()
        let poolID = UUID()
        let sharedSecret = makeKey()
        service.setCurrentPool(poolID)
        service.poolSharedSecret = sharedSecret

        let hmacKey = RelayEnvelope.deriveHMACKey(from: sharedSecret, poolID: poolID)
        let msgID = UUID()
        let envelope = makeEnvelope(
            messageID: msgID,
            originPeerID: "peer-A",
            destinationPeerID: "local",
            poolID: poolID,
            hmacKey: hmacKey
        )

        // Process once
        service.handleRelayEnvelope(envelope, from: "peer-A")
        let firstDropped = service.droppedMessageCount

        // Process again (duplicate)
        service.handleRelayEnvelope(envelope, from: "peer-A")
        XCTAssertEqual(service.droppedMessageCount, firstDropped + 1,
                        "Second processing of the same envelope must increment dropped count")

        service.clearCurrentPool()
    }

    func testDeduplicationCacheAllowsDifferentMessages() {
        let service = makeService()
        let poolID = UUID()
        let sharedSecret = makeKey()
        service.setCurrentPool(poolID)
        service.poolSharedSecret = sharedSecret

        let hmacKey = RelayEnvelope.deriveHMACKey(from: sharedSecret, poolID: poolID)

        let env1 = makeEnvelope(
            messageID: UUID(),
            originPeerID: "peer-A",
            destinationPeerID: "local",
            poolID: poolID,
            hmacKey: hmacKey
        )
        let env2 = makeEnvelope(
            messageID: UUID(),
            originPeerID: "peer-A",
            destinationPeerID: "local",
            poolID: poolID,
            hmacKey: hmacKey
        )

        let droppedBefore = service.droppedMessageCount
        service.handleRelayEnvelope(env1, from: "peer-A")
        service.handleRelayEnvelope(env2, from: "peer-A")

        // Neither should be dropped as duplicate (they may be dropped for other reasons
        // but not as duplicates)
        XCTAssertEqual(service.droppedMessageCount, droppedBefore,
                        "Two different envelopes must not be treated as duplicates")

        service.clearCurrentPool()
    }

    func testDeduplicationCacheEvictsOldEntries() {
        // Test the underlying MessageDeduplicationCache eviction
        let cache = MessageDeduplicationCache()
        var firstID: UUID?

        // Fill beyond maxCacheSize (10_000)
        for i in 0..<10_001 {
            let id = UUID()
            if i == 0 { firstID = id }
            cache.markProcessed(id)
        }

        XCTAssertLessThanOrEqual(cache.count, 10_000,
                                  "Cache must evict entries when exceeding max size")
        // The first inserted entry should have been evicted
        XCTAssertFalse(cache.hasProcessed(firstID!),
                        "Oldest entry should be evicted when cache exceeds max size")
    }

    // MARK: - HMAC on Relay Envelopes in Service

    func testHandleRelayEnvelopeRejectsInvalidHMAC() {
        let service = makeService()
        let poolID = UUID()
        let sharedSecret = makeKey()
        service.setCurrentPool(poolID)
        service.poolSharedSecret = sharedSecret

        // Create envelope with wrong HMAC (different key)
        let wrongKey = RelayEnvelope.deriveHMACKey(from: makeKey(), poolID: poolID)
        let envelope = makeEnvelope(
            originPeerID: "peer-A",
            destinationPeerID: "local",
            poolID: poolID,
            hmacKey: wrongKey
        )

        let droppedBefore = service.droppedMessageCount
        service.handleRelayEnvelope(envelope, from: "peer-A")
        XCTAssertEqual(service.droppedMessageCount, droppedBefore + 1,
                        "Envelope with invalid HMAC must be dropped")

        service.clearCurrentPool()
    }

    func testHandleRelayEnvelopeRejectsMissingHMAC() {
        let service = makeService()
        let poolID = UUID()
        let sharedSecret = makeKey()
        service.setCurrentPool(poolID)
        service.poolSharedSecret = sharedSecret

        // Create envelope without HMAC
        let envelope = makeEnvelope(
            originPeerID: "peer-A",
            destinationPeerID: "local",
            poolID: poolID,
            hmacKey: nil
        )

        let droppedBefore = service.droppedMessageCount
        service.handleRelayEnvelope(envelope, from: "peer-A")
        XCTAssertEqual(service.droppedMessageCount, droppedBefore + 1,
                        "Envelope without HMAC must be dropped when shared secret is set")

        service.clearCurrentPool()
    }

    func testHandleRelayEnvelopeRejectsPoolIDMismatch() {
        let service = makeService()
        let poolID = UUID()
        let otherPoolID = UUID()
        let sharedSecret = makeKey()
        service.setCurrentPool(poolID)
        service.poolSharedSecret = sharedSecret

        let hmacKey = RelayEnvelope.deriveHMACKey(from: sharedSecret, poolID: otherPoolID)
        let envelope = makeEnvelope(
            originPeerID: "peer-A",
            destinationPeerID: "local",
            poolID: otherPoolID,
            hmacKey: hmacKey
        )

        let droppedBefore = service.droppedMessageCount
        service.handleRelayEnvelope(envelope, from: "peer-A")
        XCTAssertEqual(service.droppedMessageCount, droppedBefore + 1,
                        "Envelope with mismatched poolID must be dropped")

        service.clearCurrentPool()
    }

    func testHandleRelayEnvelopeRejectsWhenNoPoolActive() {
        let service = makeService()
        // Do NOT call setCurrentPool

        let envelope = makeEnvelope(originPeerID: "peer-A")

        let droppedBefore = service.droppedMessageCount
        service.handleRelayEnvelope(envelope, from: "peer-A")
        XCTAssertEqual(service.droppedMessageCount, droppedBefore + 1,
                        "Envelope must be dropped when no pool is active")
    }

    // MARK: - Topology Broadcast HMAC

    func testTopologyBroadcastWithHMAC() {
        // Verify that a topology broadcast with HMAC can be round-tripped
        let sharedSecret = makeKey()
        let poolID = UUID()
        let hmacKey = RelayEnvelope.deriveHMACKey(from: sharedSecret, poolID: poolID)

        let broadcast = TopologyBroadcast(peerID: "peer-A", directNeighbors: ["peer-B", "peer-C"])
        let broadcastData = try! JSONEncoder().encode(broadcast)

        let tag = HMAC<SHA256>.authenticationCode(for: broadcastData, using: hmacKey)
        let hmacData = Data(tag)

        let wrapper = TopologyBroadcastWrapper(topologyData: broadcastData, topologyHMAC: hmacData)
        let wrappedData = try! JSONEncoder().encode(wrapper)

        // Unwrap and verify
        let result = TopologyBroadcastWrapper.unwrapWithHMAC(wrappedData)
        XCTAssertNotNil(result)
        let (unwrappedBroadcast, rawData, receivedHMAC) = result!

        XCTAssertEqual(unwrappedBroadcast.peerID, "peer-A")
        XCTAssertNotNil(receivedHMAC)

        // Verify HMAC
        let isValid = HMAC<SHA256>.isValidAuthenticationCode(
            receivedHMAC!,
            authenticating: rawData,
            using: hmacKey
        )
        XCTAssertTrue(isValid, "HMAC on topology broadcast must verify correctly")
    }

    func testTopologyBroadcastRejectsInvalidHMAC() {
        let service = makeService(localPeerID: "local")
        let poolID = UUID()
        let sharedSecret = makeKey()
        service.setCurrentPool(poolID)
        service.poolSharedSecret = sharedSecret

        // Create a topology broadcast with a wrong HMAC
        let broadcast = TopologyBroadcast(peerID: "peer-A", directNeighbors: ["peer-B"])
        let broadcastData = try! JSONEncoder().encode(broadcast)

        // Use wrong key for HMAC
        let wrongKey = RelayEnvelope.deriveHMACKey(from: makeKey(), poolID: poolID)
        let tag = HMAC<SHA256>.authenticationCode(for: broadcastData, using: wrongKey)
        let wrongHMAC = Data(tag)

        let wrapper = TopologyBroadcastWrapper(topologyData: broadcastData, topologyHMAC: wrongHMAC)
        let wrappedData = try! JSONEncoder().encode(wrapper)

        let message = PoolMessage(
            type: .system,
            senderID: "peer-A",
            senderName: "Peer A",
            payload: wrappedData
        )

        // Process the system message — should reject due to bad HMAC
        service.processSystemMessage(message)

        // If HMAC was rejected, topology should NOT have peer-A's neighbors
        let neighbors = service.meshTopology.neighbors(for: "peer-A")
        XCTAssertFalse(neighbors.contains("peer-B"),
                        "Topology broadcast with invalid HMAC must be rejected")

        service.clearCurrentPool()
    }

    func testTopologyBroadcastRejectsMissingHMACWhenSecretSet() {
        let service = makeService(localPeerID: "local")
        let poolID = UUID()
        let sharedSecret = makeKey()
        service.setCurrentPool(poolID)
        service.poolSharedSecret = sharedSecret

        // Create topology broadcast WITHOUT HMAC
        let broadcast = TopologyBroadcast(peerID: "peer-A", directNeighbors: ["peer-B"])
        let broadcastData = try! JSONEncoder().encode(broadcast)

        let wrapper = TopologyBroadcastWrapper(topologyData: broadcastData, topologyHMAC: nil)
        let wrappedData = try! JSONEncoder().encode(wrapper)

        let message = PoolMessage(
            type: .system,
            senderID: "peer-A",
            senderName: "Peer A",
            payload: wrappedData
        )

        service.processSystemMessage(message)

        let neighbors = service.meshTopology.neighbors(for: "peer-A")
        XCTAssertFalse(neighbors.contains("peer-B"),
                        "Topology broadcast without HMAC must be rejected when shared secret is set")

        service.clearCurrentPool()
    }
}

// MARK: - BFS Routing Tests

final class BFSRoutingTests: XCTestCase {

    func testBFSFindsShortestPath() {
        // A -> B -> C
        let topo = MeshTopology(localPeerID: "A")
        topo.addDirectConnection("B")
        topo.updateNeighbors(for: "B", neighbors: ["A", "C"])

        let path = topo.findPath(to: "C")
        XCTAssertEqual(path, ["B", "C"], "BFS must find 2-hop path A->B->C")
    }

    func testBFSReturnsNilForUnreachablePeer() {
        let topo = MeshTopology(localPeerID: "A")
        topo.addDirectConnection("B")
        // C is isolated — no edges connect to it

        let path = topo.findPath(to: "C")
        XCTAssertNil(path, "BFS must return nil for unreachable peer")
    }

    func testBFSHandlesDirectNeighbor() {
        let topo = MeshTopology(localPeerID: "A")
        topo.addDirectConnection("B")

        let path = topo.findPath(to: "B")
        XCTAssertEqual(path, ["B"], "Direct neighbor must have single-hop path")
    }

    func testBFSHandlesMultiHop() {
        // A -> B -> C -> D
        let topo = MeshTopology(localPeerID: "A")
        topo.addDirectConnection("B")
        topo.updateNeighbors(for: "B", neighbors: ["A", "C"])
        topo.updateNeighbors(for: "C", neighbors: ["B", "D"])

        let path = topo.findPath(to: "D")
        XCTAssertEqual(path, ["B", "C", "D"], "BFS must find 3-hop path through chain")
    }

    func testBFSPrefersShorterPaths() {
        // A -> B -> D (2 hops)
        // A -> C -> E -> D (3 hops)
        let topo = MeshTopology(localPeerID: "A")
        topo.addDirectConnection("B")
        topo.addDirectConnection("C")
        topo.updateNeighbors(for: "B", neighbors: ["A", "D"])
        topo.updateNeighbors(for: "C", neighbors: ["A", "E"])
        topo.updateNeighbors(for: "E", neighbors: ["C", "D"])

        let path = topo.findPath(to: "D")
        XCTAssertNotNil(path)
        XCTAssertEqual(path?.count, 2, "BFS must prefer the shorter 2-hop path over the 3-hop path")
        XCTAssertEqual(path?.last, "D")
    }
}

// MARK: - Integration Tests (No MultipeerConnectivity Required)

final class MeshRelayIntegrationTests: XCTestCase {

    private func makeKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    func testSharedSecretDerivationFromPoolCode() {
        // Replicate the derivation logic used in ConnectionPoolManager
        let poolCode = "TEST-POOL-CODE-12345"

        let keyData1 = SHA256.hash(data: Data(poolCode.utf8))
        let secret1 = SymmetricKey(data: keyData1)

        let keyData2 = SHA256.hash(data: Data(poolCode.utf8))
        let secret2 = SymmetricKey(data: keyData2)

        // Verify both produce the same derived HMAC key for the same pool
        let poolID = UUID()
        let hmacKey1 = RelayEnvelope.deriveHMACKey(from: secret1, poolID: poolID)
        let hmacKey2 = RelayEnvelope.deriveHMACKey(from: secret2, poolID: poolID)

        // Prove equivalence by signing the same envelope and comparing
        let envelope = RelayEnvelope(
            originPeerID: "peer-A",
            destinationPeerID: "peer-B",
            encryptedPayload: Data("hello".utf8),
            poolID: poolID
        )

        let hmac1 = envelope.computeHMAC(using: hmacKey1)
        let hmac2 = envelope.computeHMAC(using: hmacKey2)

        XCTAssertEqual(hmac1, hmac2,
                        "Same pool code must produce identical HMAC keys on different instances")
    }

    func testRelayEnvelopeRoundTripWithDerivedKey() {
        // Derive key from pool code
        let poolCode = "RELAY-TEST-CODE"
        let keyData = SHA256.hash(data: Data(poolCode.utf8))
        let sharedSecret = SymmetricKey(data: keyData)
        let poolID = UUID()
        let hmacKey = RelayEnvelope.deriveHMACKey(from: sharedSecret, poolID: poolID)

        // Create and sign envelope
        let original = RelayEnvelope(
            originPeerID: "sender",
            destinationPeerID: "receiver",
            hopPath: ["sender"],
            encryptedPayload: Data("encrypted-content".utf8),
            poolID: poolID
        ).withHMAC(using: hmacKey)

        XCTAssertTrue(original.verifyHMAC(using: hmacKey), "Original envelope HMAC must verify")

        // Simulate relay: forward the envelope
        let forwarded = original.forwarded(by: "relay-node")
        XCTAssertNotNil(forwarded)
        XCTAssertEqual(forwarded!.ttl, RelayEnvelope.defaultTTL - 1)
        XCTAssertEqual(forwarded!.hopPath, ["sender", "relay-node"])
        XCTAssertTrue(forwarded!.verifyHMAC(using: hmacKey),
                       "HMAC must remain valid after forwarding")

        // Simulate second relay
        let forwarded2 = forwarded!.forwarded(by: "relay-node-2")
        XCTAssertNotNil(forwarded2)
        XCTAssertEqual(forwarded2!.ttl, RelayEnvelope.defaultTTL - 2)
        XCTAssertEqual(forwarded2!.hopPath, ["sender", "relay-node", "relay-node-2"])
        XCTAssertTrue(forwarded2!.verifyHMAC(using: hmacKey),
                       "HMAC must remain valid after multiple forwarding hops")

        // Encode/decode round trip preserves HMAC validity
        let encoded = forwarded2!.encode()
        XCTAssertNotNil(encoded)
        let decoded = RelayEnvelope.decode(from: encoded!)
        XCTAssertNotNil(decoded)
        XCTAssertTrue(decoded!.verifyHMAC(using: hmacKey),
                       "HMAC must remain valid after JSON encode/decode round trip")
    }
}
