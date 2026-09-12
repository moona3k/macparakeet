import XCTest
@testable import MacParakeetCore

/// Consumes `spec/contracts/fixtures/share-crypto-v1.json`, the deterministic
/// synthetic fixture shared with the browser viewer. Every value here is a
/// fixed, test-only synthetic input; nothing is derived from real user
/// content or production secrets.
final class ShareCryptoEnvelopeTests: XCTestCase {
    private struct Fixture: Decodable {
        struct Envelope: Decodable {
            let schema: String
            let schemaVersion: Int
            let algorithm: String
            let nonce: String
            let ciphertext: String
        }
        struct Negative: Decodable {
            let wrongContentKey: String
            let wrongLocator: String
            let wrongContentRevision: Int
            let truncatedCiphertext: String
            let mutatedCiphertext: String
        }

        let locator: String
        let contentKey: String
        let contentRevision: Int
        let plaintext: String
        let envelope: Envelope
        let negative: Negative
    }

    private func loadFixture() throws -> Fixture {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        url.appendPathComponent("spec/contracts/fixtures/share-crypto-v1.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    func testFixtureEnvelopeDecryptsToExpectedPlaintext() throws {
        let fixture = try loadFixture()
        let locator = try ShareLocator(rawValue: fixture.locator)
        let contentKey = try ShareContentKey(rawValue: fixture.contentKey)
        let envelope = try ShareEnvelope(
            nonce: XCTUnwrap(ShareBase64URL.decode(fixture.envelope.nonce)),
            ciphertextAndTag: XCTUnwrap(ShareBase64URL.decode(fixture.envelope.ciphertext))
        )

        let opened = try ShareCryptography.open(
            envelope: envelope, contentKey: contentKey, locator: locator,
            contentRevision: fixture.contentRevision
        )

        XCTAssertEqual(String(data: opened, encoding: .utf8), fixture.plaintext)
    }

    func testSealProducesAnEnvelopeThatFixtureCanOpen() throws {
        let fixture = try loadFixture()
        let locator = try ShareLocator(rawValue: fixture.locator)
        let contentKey = try ShareContentKey(rawValue: fixture.contentKey)
        let plaintext = Data(fixture.plaintext.utf8)

        let sealed = try ShareCryptography.seal(
            plaintext: plaintext, contentKey: contentKey, locator: locator,
            contentRevision: fixture.contentRevision
        )
        let reopened = try ShareCryptography.open(
            envelope: sealed, contentKey: contentKey, locator: locator,
            contentRevision: fixture.contentRevision
        )

        XCTAssertEqual(reopened, plaintext)
    }

    func testWrongContentKeyFailsClosed() throws {
        let fixture = try loadFixture()
        let locator = try ShareLocator(rawValue: fixture.locator)
        let wrongKey = try ShareContentKey(rawValue: fixture.negative.wrongContentKey)
        let envelope = try ShareEnvelope(
            nonce: XCTUnwrap(ShareBase64URL.decode(fixture.envelope.nonce)),
            ciphertextAndTag: XCTUnwrap(ShareBase64URL.decode(fixture.envelope.ciphertext))
        )

        XCTAssertThrowsError(
            try ShareCryptography.open(
                envelope: envelope, contentKey: wrongKey, locator: locator,
                contentRevision: fixture.contentRevision
            )
        ) { error in
            XCTAssertEqual(error as? ShareCryptographyError, .authenticationFailed)
        }
    }

    func testWrongLocatorFailsClosed() throws {
        let fixture = try loadFixture()
        let wrongLocator = try ShareLocator(rawValue: fixture.negative.wrongLocator)
        let contentKey = try ShareContentKey(rawValue: fixture.contentKey)
        let envelope = try ShareEnvelope(
            nonce: XCTUnwrap(ShareBase64URL.decode(fixture.envelope.nonce)),
            ciphertextAndTag: XCTUnwrap(ShareBase64URL.decode(fixture.envelope.ciphertext))
        )

        XCTAssertThrowsError(
            try ShareCryptography.open(
                envelope: envelope, contentKey: contentKey, locator: wrongLocator,
                contentRevision: fixture.contentRevision
            )
        ) { error in
            XCTAssertEqual(error as? ShareCryptographyError, .authenticationFailed)
        }
    }

    func testWrongContentRevisionFailsClosed() throws {
        let fixture = try loadFixture()
        let locator = try ShareLocator(rawValue: fixture.locator)
        let contentKey = try ShareContentKey(rawValue: fixture.contentKey)
        let envelope = try ShareEnvelope(
            nonce: XCTUnwrap(ShareBase64URL.decode(fixture.envelope.nonce)),
            ciphertextAndTag: XCTUnwrap(ShareBase64URL.decode(fixture.envelope.ciphertext))
        )

        XCTAssertThrowsError(
            try ShareCryptography.open(
                envelope: envelope, contentKey: contentKey, locator: locator,
                contentRevision: fixture.negative.wrongContentRevision
            )
        ) { error in
            XCTAssertEqual(error as? ShareCryptographyError, .authenticationFailed)
        }
    }

    func testMutatedCiphertextByteFailsClosed() throws {
        let fixture = try loadFixture()
        let locator = try ShareLocator(rawValue: fixture.locator)
        let contentKey = try ShareContentKey(rawValue: fixture.contentKey)
        let envelope = try ShareEnvelope(
            nonce: XCTUnwrap(ShareBase64URL.decode(fixture.envelope.nonce)),
            ciphertextAndTag: XCTUnwrap(ShareBase64URL.decode(fixture.negative.mutatedCiphertext))
        )

        XCTAssertThrowsError(
            try ShareCryptography.open(
                envelope: envelope, contentKey: contentKey, locator: locator,
                contentRevision: fixture.contentRevision
            )
        ) { error in
            XCTAssertEqual(error as? ShareCryptographyError, .authenticationFailed)
        }
    }

    func testTruncatedTagFailsClosed() throws {
        let fixture = try loadFixture()
        let locator = try ShareLocator(rawValue: fixture.locator)
        let contentKey = try ShareContentKey(rawValue: fixture.contentKey)
        let envelope = try ShareEnvelope(
            nonce: XCTUnwrap(ShareBase64URL.decode(fixture.envelope.nonce)),
            ciphertextAndTag: XCTUnwrap(ShareBase64URL.decode(fixture.negative.truncatedCiphertext))
        )

        XCTAssertThrowsError(
            try ShareCryptography.open(
                envelope: envelope, contentKey: contentKey, locator: locator,
                contentRevision: fixture.contentRevision
            )
        ) { error in
            XCTAssertEqual(error as? ShareCryptographyError, .authenticationFailed)
        }
    }

    func testEnvelopeSchemaAlgorithmAndSizeBoundariesAreEnforced() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.envelope.schema, ShareEnvelope.schema)
        XCTAssertEqual(fixture.envelope.schemaVersion, ShareEnvelope.schemaVersion)
        XCTAssertEqual(fixture.envelope.algorithm, ShareEnvelope.algorithm)

        XCTAssertThrowsError(
            try ShareEnvelope(nonce: Data(repeating: 0, count: 11), ciphertextAndTag: Data(repeating: 0, count: 16)))
        XCTAssertThrowsError(
            try ShareEnvelope(nonce: Data(repeating: 0, count: 12), ciphertextAndTag: Data(repeating: 0, count: 15)))
        XCTAssertThrowsError(
            try ShareEnvelope(
                nonce: Data(repeating: 0, count: 12),
                ciphertextAndTag: Data(repeating: 0, count: ShareEnvelope.maxCiphertextAndTagBytes + 1)
            )
        )
    }

    func testEnvelopeJSONRoundTripRejectsUnknownSchemaVersionAndAlgorithm() throws {
        let fixture = try loadFixture()
        let validJSON: [String: Any] = [
            "schema": fixture.envelope.schema,
            "schemaVersion": fixture.envelope.schemaVersion,
            "algorithm": fixture.envelope.algorithm,
            "nonce": fixture.envelope.nonce,
            "ciphertext": fixture.envelope.ciphertext,
        ]
        let validData = try JSONSerialization.data(withJSONObject: validJSON)
        let decoded = try ShareEnvelope.decodedFromJSON(validData)
        XCTAssertEqual(ShareBase64URL.encode(decoded.nonce), fixture.envelope.nonce)

        var unknownVersion = validJSON
        unknownVersion["schemaVersion"] = 2
        XCTAssertThrowsError(
            try ShareEnvelope.decodedFromJSON(try JSONSerialization.data(withJSONObject: unknownVersion))
        ) { error in
            XCTAssertEqual(error as? ShareCryptographyError, .unknownSchemaVersion(2))
        }

        var unknownAlgorithm = validJSON
        unknownAlgorithm["algorithm"] = "A128GCM"
        XCTAssertThrowsError(
            try ShareEnvelope.decodedFromJSON(try JSONSerialization.data(withJSONObject: unknownAlgorithm))
        ) { error in
            XCTAssertEqual(error as? ShareCryptographyError, .unknownAlgorithm("A128GCM"))
        }

        var unknownSchema = validJSON
        unknownSchema["schema"] = "com.macparakeet.something-else"
        XCTAssertThrowsError(
            try ShareEnvelope.decodedFromJSON(try JSONSerialization.data(withJSONObject: unknownSchema))
        ) { error in
            XCTAssertEqual(error as? ShareCryptographyError, .unknownSchema("com.macparakeet.something-else"))
        }
    }

    func testUpdateNeverReusesANonceForTheSameContentKey() throws {
        let fixture = try loadFixture()
        let locator = try ShareLocator(rawValue: fixture.locator)
        let contentKey = try ShareContentKey(rawValue: fixture.contentKey)
        let plaintext = Data(fixture.plaintext.utf8)

        var seenNonces = Set<Data>()
        for revision in 1...50 {
            let envelope = try ShareCryptography.seal(
                plaintext: plaintext, contentKey: contentKey, locator: locator, contentRevision: revision
            )
            XCTAssertTrue(seenNonces.insert(envelope.nonce).inserted, "Nonce reused across content revisions")
        }
    }

    func testPlaintextOverTheSizeCeilingFailsBeforeSealing() throws {
        let fixture = try loadFixture()
        let locator = try ShareLocator(rawValue: fixture.locator)
        let contentKey = try ShareContentKey(rawValue: fixture.contentKey)
        let oversized = Data(repeating: 0x41, count: ShareBundle.maxPlaintextBytes + 1)

        XCTAssertThrowsError(
            try ShareCryptography.seal(
                plaintext: oversized, contentKey: contentKey, locator: locator, contentRevision: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? ShareCryptographyError,
                .plaintextTooLarge(byteCount: ShareBundle.maxPlaintextBytes + 1)
            )
        }
    }
}
