import XCTest
@testable import MacParakeetCore

final class MeetingPromptCandidateTests: XCTestCase {
    private let chrome = "com.google.Chrome"

    func testBrowserRequiresItsOwnMicrophoneAndRoomURL() {
        let meet = URL(string: "https://meet.google.com/abc-defg-hij")!
        XCTAssertTrue(resolve(input: chrome, urls: [:]).isEmpty)
        XCTAssertTrue(resolve(input: "com.apple.Safari", urls: [chrome: [meet]]).isEmpty)
        XCTAssertEqual(resolve(input: chrome, urls: [chrome: [meet]]).first?.displayName, "Google Meet")
        XCTAssertTrue(
            MeetingPromptCandidateResolver.resolve(
                audio: ProcessAudioSnapshot(processes: [process(chrome, input: false, output: true)]),
                meetingURLsByBundleID: [chrome: [meet]]
            ).isEmpty)
    }

    func testHelpersAreNormalizedWithoutBroadPrefixMatching() {
        let urls = [chrome: [URL(string: "https://meet.google.com/abc-defg-hij")!]]
        for bundleID in [chrome, chrome + ".helper", chrome + ".helper.renderer", chrome + ".Helper.GPU"] {
            XCTAssertEqual(resolve(input: bundleID, urls: urls).first?.bundleID, chrome)
        }
        for bundleID in [chrome + "Evil", chrome + ".helperEvil", "com.apple.WebKit.GPU"] {
            XCTAssertTrue(resolve(input: bundleID, urls: urls).isEmpty)
        }
    }

    func testOperaAndOperaGXAreSupportedWithTheirOwnHelperProcesses() {
        let meet = URL(string: "https://meet.google.com/abc-defg-hij")!
        for browser in ["com.operasoftware.Opera", "com.operasoftware.OperaGX", "com.brave.Browser"] {
            for suffix in ["", ".helper", ".helper.renderer"] {
                XCTAssertEqual(resolve(input: browser + suffix, urls: [browser: [meet]]).first?.bundleID, browser)
            }
            XCTAssertTrue(resolve(input: browser + "Unrelated", urls: [browser: [meet]]).isEmpty)
        }
    }

    func testExplicitPreJoinEvidenceExcludesRoomDespiteMicrophonePreview() {
        let meet = URL(string: "https://meet.google.com/abc-defg-hij")!
        let anotherRoom = URL(string: "https://meet.google.com/xyz-defg-hij")!
        let audio = ProcessAudioSnapshot(processes: [process(chrome, input: true, output: true)])
        func resolve(excluded: [URL], confirmed: [URL] = []) -> [MeetingPromptCandidate] {
            MeetingPromptCandidateResolver.resolve(
                audio: audio, meetingURLsByBundleID: [chrome: [meet]],
                confirmedInCallURLsByBundleID: [chrome: confirmed],
                excludedPreJoinURLsByBundleID: [chrome: excluded]
            )
        }
        XCTAssertTrue(resolve(excluded: [meet]).isEmpty)
        XCTAssertEqual(resolve(excluded: [anotherRoom]).count, 1)
        // Fresh positive in-call evidence wins over a cached pre-join result.
        XCTAssertEqual(resolve(excluded: [meet], confirmed: [meet]).count, 1)
    }

    func testDuplicatePreJoinRoomsDoNotBorrowBrowserMicrophoneFromAnotherTab() throws {
        let otherRoom = try XCTUnwrap(URL(string: "https://meet.google.com/xyz-defg-hij"))
        let audio = ProcessAudioSnapshot(processes: [process(chrome, input: true, output: true)])
        for address in [
            "https://us02web.zoom.us/j/12345678901",
            "https://teams.microsoft.com/meet/12345678",
        ] {
            let room = try XCTUnwrap(URL(string: address))
            let duplicate = room.appending(queryItems: [.init(name: "source", value: "another-tab")])
            let candidates = MeetingPromptCandidateResolver.resolve(
                audio: audio, meetingURLsByBundleID: [chrome: [room, duplicate, otherRoom]],
                excludedPreJoinURLsByBundleID: [chrome: [room]]
            )
            XCTAssertEqual(candidates.count, 1)
            XCTAssertEqual(
                candidates.first?.id,
                MeetingPromptCandidateResolver.browserCandidate(bundleID: chrome, meetingURL: otherRoom)?.id)
        }
    }

    func testMutedMeetRequiresPositiveInCallEvidenceForTheSameRoomAndBrowser() {
        let meet = URL(string: "https://meet.google.com/abc-defg-hij")!
        let otherRoom = URL(string: "https://meet.google.com/xyz-defg-hij")!
        let noAudio = ProcessAudioSnapshot(processes: [])
        func resolve(confirmed: [String: [URL]]) -> [MeetingPromptCandidate] {
            MeetingPromptCandidateResolver.resolve(
                audio: noAudio, meetingURLsByBundleID: [chrome: [meet]],
                confirmedInCallURLsByBundleID: confirmed
            )
        }
        XCTAssertTrue(resolve(confirmed: [:]).isEmpty)
        XCTAssertTrue(resolve(confirmed: [chrome: [otherRoom]]).isEmpty)
        XCTAssertTrue(resolve(confirmed: ["com.apple.Safari": [meet]]).isEmpty)
        XCTAssertEqual(resolve(confirmed: [chrome: [meet]]).first?.displayName, "Google Meet")
    }

    func testNoMicConfirmationDoesNotAcceptOtherProvidersOrUnknownBrowser() {
        let zoom = URL(string: "https://zoom.us/j/12345678901")!
        let noAudio = ProcessAudioSnapshot(processes: [])
        XCTAssertTrue(
            MeetingPromptCandidateResolver.resolve(
                audio: noAudio, meetingURLsByBundleID: [chrome: [zoom]],
                confirmedInCallURLsByBundleID: [chrome: [zoom]]
            ).isEmpty)
        let meet = URL(string: "https://meet.google.com/abc-defg-hij")!
        XCTAssertTrue(
            MeetingPromptCandidateResolver.resolve(
                audio: noAudio, meetingURLsByBundleID: ["untrusted": [meet]],
                confirmedInCallURLsByBundleID: ["untrusted": [meet]]
            ).isEmpty)
    }

    func testStrictRoomRoutesRejectHomePagesLookalikeHostsAndCredentials() {
        for value in [
            "https://meet.google.com/", "https://meet.google.com/landing", "https://meet.google.com/lookup/foo",
            "https://meet.google.com.evil.test/abc-defg-hij", "https://evil.test/meet.google.com/abc-defg-hij",
            "https://zoom.us/", "https://zoom.us/profile", "https://zoom.us/j/123", "https://evilzoom.us/j/123456789",
            "https://teams.microsoft.com/", "https://teams.microsoft.com/v2/", "https://teams.microsoft.com/l/chat/0/0",
            "https://user:secret@meet.google.com/abc-defg-hij", "https://meet.google.com:8443/abc-defg-hij",
            "file://meet.google.com/abc-defg-hij",
        ] {
            XCTAssertFalse(MeetingPromptCandidateResolver.isMeetingURL(URL(string: value)!), value)
        }
    }

    func testRoomIdentityIgnoresQueryAndFragmentButDistinguishesCalls() throws {
        let first = resolve(
            input: chrome, urls: [chrome: [URL(string: "https://meet.google.com/abc-defg-hij?authuser=0#foo")!]])
        let second = resolve(
            input: chrome, urls: [chrome: [URL(string: "https://meet.google.com/abc-defg-hij?authuser=1")!]])
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 1)
        let candidate = try XCTUnwrap(first.first)
        XCTAssertFalse(candidate.id.contains("authuser"))
        XCTAssertNotEqual(
            first, resolve(input: chrome, urls: [chrome: [URL(string: "https://meet.google.com/xyz-defg-hij")!]]))
    }

    func testZoomRoutesAndTeamsEncodedRoomAreAccepted() {
        for value in [
            "https://company.zoom.us/j/12345678901?pwd=secret", "https://zoomgov.com/w/123456789",
            "https://app.zoom.us/wc/12345678901/join", "https://zoom.us/my/example.room",
            "https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0?context=private",
            "https://teams.live.com/meet/123456789", "https://teams.cloud.microsoft/meet/123456789",
        ] {
            XCTAssertTrue(MeetingPromptCandidateResolver.isMeetingURL(URL(string: value)!), value)
        }
        let urls = ["https://company.zoom.us/j/12345678901?pwd=secret", "https://app.zoom.us/wc/12345678901/join"].map {
            URL(string: $0)!
        }
        XCTAssertEqual(resolve(input: chrome, urls: [chrome: urls]).count, 1)
    }

    func testDedicatedAppsRequireInputAndSlackRequiresFullDuplex() {
        XCTAssertEqual(resolve(input: "us.zoom.xos", urls: [:]).first?.app, .zoom)
        XCTAssertTrue(resolve(input: "com.tinyspeck.slackmacgap", urls: [:]).isEmpty)
        let slack = "com.tinyspeck.slackmacgap"
        let audio = ProcessAudioSnapshot(processes: [
            process(slack, input: true, output: false), process(slack, input: false, output: true),
        ])
        XCTAssertEqual(
            MeetingPromptCandidateResolver.resolve(audio: audio, meetingURLsByBundleID: [:]).first?.app, .slack)
    }

    func testUnknownAppsAndOwnDictationCannotTriggerDetection() {
        for bundleID in ["com.macparakeet.MacParakeet", "com.apple.VoiceMemos", "unknown"] {
            XCTAssertTrue(resolve(input: bundleID, urls: [:]).isEmpty)
        }
    }

    private func resolve(input: String, urls: [String: [URL]]) -> [MeetingPromptCandidate] {
        MeetingPromptCandidateResolver.resolve(
            audio: ProcessAudioSnapshot(processes: [process(input, input: true, output: false)]),
            meetingURLsByBundleID: urls
        )
    }

    private func process(_ bundleID: String, input: Bool, output: Bool) -> AudioProcessActivity {
        AudioProcessActivity(pid: input ? 1 : 2, bundleID: bundleID, isRunningInput: input, isRunningOutput: output)
    }
}
