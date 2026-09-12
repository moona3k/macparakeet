import XCTest
@testable import MacParakeetCore

/// Records the last request it saw and returns a scripted response, so tests
/// never need a live network connection.
private final class FakeShareHTTPTransport: ShareHTTPTransport, @unchecked Sendable {
    private(set) var lastRequest: ShareHTTPRequest?
    private(set) var lastOrigin: URL?
    var nextResponse: Result<ShareHTTPResponse, Error> = .success(ShareHTTPResponse(statusCode: 200, body: Data()))

    func send(_ request: ShareHTTPRequest, origin: URL) async throws -> ShareHTTPResponse {
        lastRequest = request
        lastOrigin = origin
        return try nextResponse.get()
    }
}

final class ShareRemoteClientTests: XCTestCase {
    private var transport: FakeShareHTTPTransport!
    var client: ShareRemoteClient!

    override func setUp() {
        transport = FakeShareHTTPTransport()
        client = ShareRemoteClient(origin: .production, transport: transport)
    }

    private func jsonResponse(_ statusCode: Int, _ object: some Encodable) throws -> ShareHTTPResponse {
        ShareHTTPResponse(statusCode: statusCode, body: try ShareServiceJSON.makeEncoder().encode(object))
    }

    // MARK: - Request shape

    func testPersistedMutationReplaysExactBytesAndPrecondition() async throws {
        let body = Data("{ \"expiresAt\" : \"2026-10-01T00:00:00Z\" }".utf8)
        let operation = ShareOutboxOperation(sharePublicationId: UUID(), sequence: 1, kind: .expiryChange,
            idempotencyKey: "same-key", requestBody: body, ifMatch: "\"v8\"")
        transport.nextResponse = .success(try jsonResponse(200, makeConfirmedResource(shareId: "share",
            locatorCommitment: "commitment", contentRevision: 1, version: 9,
            expiresAt: Date(timeIntervalSince1970: 1000), maxExpiresAt: Date(timeIntervalSince1970: 2000))))
        _ = try await client.sendPersistedOperation(operation, shareId: "share", deviceToken: .generate())
        XCTAssertEqual(transport.lastRequest?.body, body)
        XCTAssertEqual(transport.lastRequest?.headers["If-Match"], "\"v8\"")
        XCTAssertEqual(transport.lastRequest?.headers["Idempotency-Key"], "same-key")
    }

    func testOpaqueCursorIsOneQueryValue() async throws {
        transport.nextResponse = .success(try jsonResponse(200, ShareListPage(shares: [], nextCursor: nil)))
        _ = try await client.listShares(deviceToken: .generate(), cursor: "a&limit=999#fragment", limit: 50)
        let path = try XCTUnwrap(transport.lastRequest?.path)
        let components = try XCTUnwrap(URLComponents(string: path))
        XCTAssertEqual(components.queryItems?.count, 2)
        XCTAssertEqual(components.queryItems?.last?.value, "a&limit=999#fragment")
    }

    func testEnrollOwnerSendsCreateOnlyPreconditionAndIdempotencyKey() async throws {
        transport.nextResponse = .success(
            try jsonResponse(201, ShareOwnerMetadata(ownerId: "owner-1", credentialGeneration: 1, recoveryVerifier: nil))
        )

        let metadata = try await client.enrollOwner(
            ownerId: "owner-1",
            deviceSelector: "selector-1",
            deviceVerifier: "verifier-1",
            recoveryVerifier: nil,
            idempotencyKey: "idem-1"
        )

        XCTAssertEqual(metadata.ownerId, "owner-1")
        XCTAssertEqual(metadata.credentialGeneration, 1)
        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/v1/owners")
        XCTAssertEqual(request.headers["If-None-Match"], "*")
        XCTAssertEqual(request.headers["Idempotency-Key"], "idem-1")
        XCTAssertNil(request.headers["Authorization"], "enrollment authenticates by body, not a bearer header")
    }

    func testCreateShareSendsOwnerBearerAndCreateOnlyPrecondition() async throws {
        let token = ShareDeviceToken.generate()
        let locator = ShareLocator.generate()
        let envelope = try ShareCryptography.seal(
            plaintext: Data("{}".utf8), contentKey: .generate(), locator: locator, contentRevision: 1
        )
        transport.nextResponse = .success(
            try jsonResponse(
                201,
                ShareResource(
                    id: "share-1", locatorCommitment: "commitment", contentRevision: 1, version: 1,
                    contentWritable: true, accessState: .active, deletionState: .retained, ciphertextBytes: 2,
                    createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
                    expiresAt: Date(timeIntervalSince1970: 1000), maxExpiresAt: Date(timeIntervalSince1970: 2000),
                    terminalAt: nil
                )
            )
        )

        let resource = try await client.createShare(
            deviceToken: token, shareId: "share-1", locator: locator.rawValue, contentRevision: 1,
            expiresAt: Date(timeIntervalSince1970: 1000), envelope: envelope, idempotencyKey: "idem-2"
        )

        XCTAssertEqual(resource.id, "share-1")
        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.method, "PUT")
        XCTAssertEqual(request.path, "/api/v1/shares/share-1")
        XCTAssertEqual(request.headers["Authorization"], token.authorizationHeaderValue)
        XCTAssertEqual(request.headers["If-None-Match"], "*")
        XCTAssertNil(request.headers["If-Match"])
    }

    func testUpdateShareContentSendsIfMatchInsteadOfCreatePrecondition() async throws {
        let token = ShareDeviceToken.generate()
        let locator = ShareLocator.generate()
        let envelope = try ShareCryptography.seal(
            plaintext: Data("{}".utf8), contentKey: .generate(), locator: locator, contentRevision: 2
        )
        transport.nextResponse = .success(
            try jsonResponse(
                200,
                ShareResource(
                    id: "share-1", locatorCommitment: "commitment", contentRevision: 2, version: 5,
                    contentWritable: true, accessState: .active, deletionState: .retained, ciphertextBytes: 2,
                    createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0),
                    expiresAt: Date(timeIntervalSince1970: 1000), maxExpiresAt: Date(timeIntervalSince1970: 2000),
                    terminalAt: nil
                )
            )
        )

        _ = try await client.updateShareContent(
            deviceToken: token, shareId: "share-1", locator: locator.rawValue, contentRevision: 2,
            envelope: envelope, ifMatch: "\"v4\"", idempotencyKey: "idem-3"
        )

        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.headers["If-Match"], "\"v4\"")
        XCTAssertNil(request.headers["If-None-Match"])
    }

    func testRecoveryConfigurationSendsRecoveryAuthorizationOnlyWhenReplacingOrRemoving() async throws {
        let token = ShareDeviceToken.generate()
        let currentRecovery = ShareRecoveryToken.generate(ownerId: ShareRandom.bytes(16))
        transport.nextResponse = .success(
            try jsonResponse(200, ShareOwnerMetadata(ownerId: "owner-1", credentialGeneration: 1, recoveryVerifier: "v2"))
        )

        _ = try await client.configureRecovery(
            deviceToken: token, recoveryVerifier: "v2", isInitialSetup: false,
            currentRecoveryToken: currentRecovery, idempotencyKey: "idem-4"
        )

        let request = try XCTUnwrap(transport.lastRequest)
        XCTAssertEqual(request.headers["Recovery-Authorization"], currentRecovery.authorizationHeaderValue)
        XCTAssertNil(request.headers["If-None-Match"], "only initial setup uses the absence precondition")
    }

    // MARK: - Error mapping

    func testNonSuccessStatusDecodesStableCodeAndDropsMessage() async throws {
        let errorJSON = """
            {"error":{"code":"version_conflict","message":"human copy that must not be relied on","retryable":false,"requestId":"req-1"}}
            """
        transport.nextResponse = .success(ShareHTTPResponse(statusCode: 412, body: Data(errorJSON.utf8)))

        do {
            _ = try await client.capabilities()
            XCTFail("expected a thrown ShareClientError")
        } catch ShareClientError.api(let apiError) {
            XCTAssertEqual(apiError.code, .versionConflict)
            XCTAssertFalse(apiError.retryable)
            XCTAssertEqual(apiError.requestId, "req-1")
        }
    }

    func testUnrecognizedErrorCodeFailsClosedInsteadOfCrashingDecode() async throws {
        let errorJSON = """
            {"error":{"code":"some_future_code","message":"n/a","retryable":true,"requestId":"req-2"}}
            """
        transport.nextResponse = .success(ShareHTTPResponse(statusCode: 500, body: Data(errorJSON.utf8)))

        do {
            _ = try await client.capabilities()
            XCTFail("expected a thrown ShareClientError")
        } catch ShareClientError.api(let apiError) {
            XCTAssertEqual(apiError.code, .unrecognized)
            XCTAssertTrue(apiError.retryable)
        }
    }

    func testTransportNetworkFailureSurfacesAsClientNetworkError() async {
        transport.nextResponse = .failure(ShareTransportError.network)
        do {
            _ = try await client.capabilities()
            XCTFail("expected .network")
        } catch ShareClientError.network {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Origin enforcement (real transport, no network reached)

    func testRealTransportRejectsAnUnapprovedOrigin() async {
        let realTransport = URLSessionShareHTTPTransport()
        let request = ShareHTTPRequest(method: "GET", path: "/api/v1/capabilities")
        do {
            _ = try await realTransport.send(request, origin: URL(string: "http://share.macparakeet.com")!)
            XCTFail("expected unapprovedOrigin for a non-HTTPS origin")
        } catch ShareTransportError.unapprovedOrigin {
            // expected — rejected before any network I/O
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRealTransportRejectsARequestThatResolvesOffOrigin() async {
        let realTransport = URLSessionShareHTTPTransport()
        // An absolute path escaping to a different host must never be sent.
        let request = ShareHTTPRequest(method: "GET", path: "https://attacker.example/api/v1/capabilities")
        do {
            _ = try await realTransport.send(request, origin: URL(string: "https://share.macparakeet.com")!)
            XCTFail("expected unapprovedOrigin")
        } catch ShareTransportError.unapprovedOrigin {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
