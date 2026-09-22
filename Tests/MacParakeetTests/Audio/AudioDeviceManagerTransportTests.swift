import CoreAudio
import XCTest
@testable import MacParakeetCore

final class AudioDeviceManagerTransportTests: XCTestCase {
    func testBluetoothTransportTypesClassifyAsBluetooth() {
        XCTAssertTrue(
            AudioDeviceManager.isBluetoothTransportType(kAudioDeviceTransportTypeBluetooth)
        )
        XCTAssertTrue(
            AudioDeviceManager.isBluetoothTransportType(kAudioDeviceTransportTypeBluetoothLE)
        )
    }

    func testNonBluetoothTransportTypesDoNotClassifyAsBluetooth() {
        XCTAssertFalse(
            AudioDeviceManager.isBluetoothTransportType(kAudioDeviceTransportTypeBuiltIn)
        )
        XCTAssertFalse(
            AudioDeviceManager.isBluetoothTransportType(kAudioDeviceTransportTypeUSB)
        )
        XCTAssertFalse(
            AudioDeviceManager.isBluetoothTransportType(kAudioDeviceTransportTypeAggregate)
        )
        XCTAssertFalse(
            AudioDeviceManager.isBluetoothTransportType(kAudioDeviceTransportTypeVirtual)
        )
        XCTAssertFalse(AudioDeviceManager.isBluetoothTransportType(0))
    }

    func testDirectBluetoothInputClassifiesAsBluetooth() {
        XCTAssertTrue(
            AudioDeviceManager.isBluetoothInput(
                transport: kAudioDeviceTransportTypeBluetooth,
                activeSubDeviceTransports: []
            )
        )
        XCTAssertTrue(
            AudioDeviceManager.isBluetoothInput(
                transport: kAudioDeviceTransportTypeBluetoothLE,
                activeSubDeviceTransports: []
            )
        )
    }

    func testAggregateWithAnyBluetoothSubDeviceClassifiesAsBluetooth() {
        // The Bluetooth member need not be first: an aggregate holds every
        // sub-device's input stream open, so any Bluetooth member pins the
        // headset in HFP/SCO.
        XCTAssertTrue(
            AudioDeviceManager.isBluetoothInput(
                transport: kAudioDeviceTransportTypeAggregate,
                activeSubDeviceTransports: [
                    kAudioDeviceTransportTypeBuiltIn,
                    kAudioDeviceTransportTypeBluetooth,
                ]
            )
        )
    }

    func testAggregateWithoutBluetoothSubDevicesDoesNotClassifyAsBluetooth() {
        XCTAssertFalse(
            AudioDeviceManager.isBluetoothInput(
                transport: kAudioDeviceTransportTypeAggregate,
                activeSubDeviceTransports: [
                    kAudioDeviceTransportTypeBuiltIn,
                    kAudioDeviceTransportTypeUSB,
                ]
            )
        )
        XCTAssertFalse(
            AudioDeviceManager.isBluetoothInput(
                transport: kAudioDeviceTransportTypeAggregate,
                activeSubDeviceTransports: []
            )
        )
    }

    func testNonAggregateNonBluetoothIgnoresSubDeviceTransports() {
        XCTAssertFalse(
            AudioDeviceManager.isBluetoothInput(
                transport: kAudioDeviceTransportTypeUSB,
                activeSubDeviceTransports: [kAudioDeviceTransportTypeBluetooth]
            )
        )
    }

    func testBluetoothRouteStatePreservesUnknownTransport() {
        XCTAssertNil(
            AudioDeviceManager.bluetoothRouteState(
                transport: nil,
                activeSubDeviceTransports: []
            )
        )
        XCTAssertNil(
            AudioDeviceManager.bluetoothRouteState(
                transport: kAudioDeviceTransportTypeUnknown,
                activeSubDeviceTransports: []
            )
        )
    }

    func testBluetoothRouteStatePreservesUnknownAggregateSubDevices() {
        XCTAssertNil(
            AudioDeviceManager.bluetoothRouteState(
                transport: kAudioDeviceTransportTypeAggregate,
                activeSubDeviceTransports: nil
            )
        )
        XCTAssertNil(
            AudioDeviceManager.bluetoothRouteState(
                transport: kAudioDeviceTransportTypeAggregate,
                activeSubDeviceTransports: []
            )
        )
    }

    func testOrdinaryBluetoothInputClassificationKeepsUnknownTransportNonBluetooth() {
        XCTAssertFalse(
            AudioDeviceManager.isBluetoothInput(
                transport: kAudioDeviceTransportTypeUnknown,
                activeSubDeviceTransports: []
            )
        )
    }

    func testBluetoothRouteStateKeepsKnownNonBluetoothRouteSafe() {
        XCTAssertEqual(
            AudioDeviceManager.bluetoothRouteState(
                transport: kAudioDeviceTransportTypeUSB,
                activeSubDeviceTransports: nil
            ),
            false
        )
    }
}
