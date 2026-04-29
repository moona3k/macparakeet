import CoreAudio
import Foundation
import MacParakeetCore

struct AudioInputDiagnostics {
    let devices: [AudioDeviceManager.InputDevice]
    let defaultDevice: AudioDeviceManager.InputDevice?
    let storedSelectedUID: String?

    var selectedDevice: AudioDeviceManager.InputDevice? {
        guard let storedSelectedUID else { return nil }
        return devices.first { $0.uid == storedSelectedUID }
    }

    var builtInDevice: AudioDeviceManager.InputDevice? {
        devices.first(where: \.isBuiltIn)
    }

    var fallbackOrder: [AudioDeviceManager.InputDevice] {
        var result: [AudioDeviceManager.InputDevice] = []
        var seenIDs = Set<AudioDeviceID>()

        func append(_ device: AudioDeviceManager.InputDevice?) {
            guard let device, seenIDs.insert(device.id).inserted else { return }
            result.append(device)
        }

        append(selectedDevice)
        append(defaultDevice)
        append(builtInDevice)
        return result
    }
}

func loadAudioInputDiagnostics(
    defaults: UserDefaults = macParakeetAppDefaults(),
    inputDevices: () -> [AudioDeviceManager.InputDevice] = { AudioDeviceManager.inputDevices() },
    defaultInputDeviceInfo: () -> AudioDeviceManager.InputDevice? = {
        AudioDeviceManager.defaultInputDeviceInfo()
    }
) -> AudioInputDiagnostics {
    let preferences = UserDefaultsAppRuntimePreferences(defaults: defaults)
    return AudioInputDiagnostics(
        devices: inputDevices(),
        defaultDevice: defaultInputDeviceInfo(),
        storedSelectedUID: preferences.selectedMicrophoneDeviceUID
    )
}

func printAudioInputDiagnostics(_ diagnostics: AudioInputDiagnostics) {
    for line in audioInputDiagnosticsLines(diagnostics) {
        print(line)
    }
}

func audioInputDiagnosticsLines(_ diagnostics: AudioInputDiagnostics) -> [String] {
    var lines = [String]()

    lines.append("  System default: \(formatOptionalDevice(diagnostics.defaultDevice))")

    if diagnostics.storedSelectedUID != nil {
        if let selectedDevice = diagnostics.selectedDevice {
            lines.append(
                "  Stored selection: \(formatDevice(selectedDevice, markers: ["selected", "available"]))"
            )
        } else {
            lines.append("  Stored selection: Unavailable (stored device is not currently connected)")
        }
    } else {
        lines.append("  Stored selection: System Default")
    }

    if diagnostics.fallbackOrder.isEmpty {
        lines.append("  Effective fallback order: None")
    } else {
        lines.append("  Effective fallback order:")
        for (index, device) in diagnostics.fallbackOrder.enumerated() {
            let markers = fallbackMarkers(for: device, diagnostics: diagnostics)
            lines.append("    \(index + 1). \(formatDevice(device, markers: markers))")
        }
    }

    if diagnostics.devices.isEmpty {
        lines.append("  Devices: None reported by CoreAudio")
    } else {
        lines.append("  Devices:")
        for device in diagnostics.devices {
            let markers = deviceMarkers(for: device, diagnostics: diagnostics)
            lines.append("    - \(formatDevice(device, markers: markers))")
        }
    }

    return lines
}

private func fallbackMarkers(
    for device: AudioDeviceManager.InputDevice,
    diagnostics: AudioInputDiagnostics
) -> [String] {
    var markers = [String]()
    if diagnostics.selectedDevice?.id == device.id {
        markers.append("selected")
    }
    if diagnostics.defaultDevice?.id == device.id {
        markers.append("system default")
    }
    if diagnostics.builtInDevice?.id == device.id {
        markers.append("built-in fallback")
    }
    return markers
}

private func deviceMarkers(
    for device: AudioDeviceManager.InputDevice,
    diagnostics: AudioInputDiagnostics
) -> [String] {
    var markers = [String]()
    if diagnostics.defaultDevice?.id == device.id {
        markers.append("system default")
    }
    if diagnostics.selectedDevice?.id == device.id {
        markers.append("selected")
    }
    return markers
}

private func formatOptionalDevice(_ device: AudioDeviceManager.InputDevice?) -> String {
    guard let device else { return "Unavailable" }
    return formatDevice(device)
}

private func formatDevice(
    _ device: AudioDeviceManager.InputDevice,
    markers: [String] = []
) -> String {
    let tags = ([device.transportLabel] + markers).joined(separator: ", ")
    return "\(device.name) [\(tags)]"
}
