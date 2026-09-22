import Darwin
import Foundation
import MacParakeetCore

// Chrome owns this process. stdout is exclusively the native messaging stream.
// The extension never receives the local pairing secret or the Jev API key.
do {
    let configuration = try VoiceControlBrowserWire.configuration()
    guard CommandLine.arguments.count == 2,
        CommandLine.arguments[1] == configuration.extensionOrigin
    else {
        throw VoiceControlBrowserWire.WireError.invalidConfiguration
    }
    let descriptor = try VoiceControlBrowserWire.makeSocket()
    defer { Darwin.close(descriptor) }
    let result = try VoiceControlBrowserWire.withAddress(VoiceControlBrowserWire.socketPath) {
        Darwin.connect(descriptor, $0, $1)
    }
    guard result == 0 else { throw VoiceControlBrowserWire.WireError.socketFailure }
    let hello = try JSONSerialization.data(withJSONObject: [
        "type": "hostHello", "token": configuration.token, "origin": configuration.extensionOrigin,
    ])
    try VoiceControlBrowserWire.writeFrame(hello, to: descriptor)
    let acknowledgement = try VoiceControlBrowserWire.readFrame(from: descriptor)
    guard let object = try JSONSerialization.jsonObject(with: acknowledgement) as? [String: Any],
        object["type"] as? String == "hostReady"
    else {
        throw VoiceControlBrowserWire.WireError.invalidConfiguration
    }
    DispatchQueue(label: "voice-control.native-host.input").async {
        do {
            while true {
                let data = try VoiceControlBrowserWire.readFrame(from: STDIN_FILENO)
                try VoiceControlBrowserWire.writeFrame(data, to: descriptor)
            }
        } catch {
            Darwin.shutdown(descriptor, SHUT_RDWR)
        }
    }
    while true {
        let data = try VoiceControlBrowserWire.readFrame(from: descriptor)
        try VoiceControlBrowserWire.writeFrame(data, to: STDOUT_FILENO)
    }
} catch {
    // Deliberately omit error payloads: they may contain remote page data.
    FileHandle.standardError.write(Data("Voice Control browser bridge disconnected.\n".utf8))
    exit(1)
}
