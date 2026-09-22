import Darwin
import Foundation
import XCTest
@testable import MacParakeetCore

final class VoiceControlBrowserRegistrationTests: XCTestCase {
    private let firstID = String(repeating: "a", count: 32)
    private let secondID = String(repeating: "b", count: 32)
    private var host: URL { URL(fileURLWithPath: "/usr/bin/true") }
    private func home() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "browser-registration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func config(_ home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/MacParakeet/VoiceControlBrowser/pairing.json")
    }
    private func manifest(_ home: URL) -> URL {
        home.appendingPathComponent(
            "Library/Application Support/Google/Chrome/NativeMessagingHosts/com.macparakeet.voice_control.json")
    }

    func testRegistersPrivatePairingAndExactOriginIdempotently() async throws {
        let home = try home(), registration = VoiceControlBrowserRegistration(homeDirectory: home)
        try await registration.register(extensionID: firstID, browser: .chrome, hostURL: host)
        let first = try JSONDecoder().decode(
            VoiceControlBrowserWire.Configuration.self, from: Data(contentsOf: config(home)))
        XCTAssertEqual(first.extensionOrigin, "chrome-extension://\(firstID)/")
        XCTAssertEqual(first.token.count, 64)
        let attributes = try FileManager.default.attributesOfItem(atPath: config(home).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: manifest(home))) as? [String: Any])
        XCTAssertEqual(decoded["allowed_origins"] as? [String], [first.extensionOrigin])
        XCTAssertEqual(decoded["path"] as? String, host.path)
        try await registration.register(extensionID: firstID, browser: .chrome, hostURL: host)
        let second = try JSONDecoder().decode(
            VoiceControlBrowserWire.Configuration.self, from: Data(contentsOf: config(home)))
        XCTAssertEqual(first.token, second.token)
    }

    func testDifferentPairingRequiresExplicitReplacement() async throws {
        let home = try home(), registration = VoiceControlBrowserRegistration(homeDirectory: home)
        try await registration.register(extensionID: firstID, browser: .chrome, hostURL: host)
        let original = try Data(contentsOf: config(home))
        do {
            try await registration.register(extensionID: secondID, browser: .chrome, hostURL: host)
            XCTFail("Replacement should require deliberate opt-in")
        } catch VoiceControlBrowserRegistration.RegistrationError.conflictingPairing {}
        XCTAssertEqual(try Data(contentsOf: config(home)), original)
        try await registration.register(extensionID: secondID, browser: .chrome, hostURL: host, replaceExisting: true)
        let replaced = try JSONDecoder().decode(
            VoiceControlBrowserWire.Configuration.self, from: Data(contentsOf: config(home)))
        XCTAssertEqual(replaced.extensionOrigin, "chrome-extension://\(secondID)/")
        XCTAssertNotEqual(try Data(contentsOf: config(home)), original)
    }

    func testInvalidIDAndMissingHostCreateNoPairing() async throws {
        let home = try home(), registration = VoiceControlBrowserRegistration(homeDirectory: home)
        do {
            try await registration.register(extensionID: "../wrong", browser: .chrome, hostURL: host)
            XCTFail("Invalid ID accepted")
        } catch VoiceControlBrowserRegistration.RegistrationError.invalidExtensionID {}
        do {
            try await registration.register(
                extensionID: firstID, browser: .chrome, hostURL: home.appendingPathComponent("missing"))
            XCTFail("Missing host accepted")
        } catch VoiceControlBrowserRegistration.RegistrationError.missingHost {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: config(home).path))
    }

    func testPreservesForeignManifestAndSymbolicLink() async throws {
        let home = try home(), registration = VoiceControlBrowserRegistration(homeDirectory: home)
        let manifest = manifest(home)
        try FileManager.default.createDirectory(
            at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let foreign = Data("unrelated configuration".utf8)
        try foreign.write(to: manifest)
        do {
            try await registration.register(extensionID: firstID, browser: .chrome, hostURL: host)
            XCTFail("Foreign manifest replaced")
        } catch VoiceControlBrowserRegistration.RegistrationError.conflictingManifest {}
        XCTAssertEqual(try Data(contentsOf: manifest), foreign)
        XCTAssertFalse(FileManager.default.fileExists(atPath: config(home).path))
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createSymbolicLink(at: manifest, withDestinationURL: host)
        do {
            try await registration.register(extensionID: firstID, browser: .chrome, hostURL: host)
            XCTFail("Symbolic link followed")
        } catch VoiceControlBrowserRegistration.RegistrationError.insecurePath {}
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: manifest.path), host.path)
    }

    func testActiveBridgeLockPreventsReconfiguration() async throws {
        let home = try home(), registration = VoiceControlBrowserRegistration(homeDirectory: home)
        try await registration.register(extensionID: firstID, browser: .chrome, hostURL: host)
        let path = config(home).deletingLastPathComponent().appendingPathComponent("bridge.lock").path
        let descriptor = Darwin.open(path, O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        do {
            try await registration.register(
                extensionID: secondID, browser: .chrome, hostURL: host, replaceExisting: true)
            XCTFail("Reconfiguration while bridge active")
        } catch VoiceControlBrowserRegistration.RegistrationError.bridgeRunning {}
        let current = try JSONDecoder().decode(
            VoiceControlBrowserWire.Configuration.self, from: Data(contentsOf: config(home)))
        XCTAssertEqual(current.extensionOrigin, "chrome-extension://\(firstID)/")
    }
}
