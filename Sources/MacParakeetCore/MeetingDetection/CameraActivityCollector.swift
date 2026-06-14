import CoreMediaIO
import Foundation
import OSLog

public final class CameraActivityCollector: @unchecked Sendable {
    public typealias StateHandler = @Sendable (Bool) -> Void

    private struct DeviceListener {
        let deviceID: CMIOObjectID
        let block: CMIOObjectPropertyListenerBlock
    }

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "CameraActivityCollector")
    private let lock = NSLock()
    private let listenerQueue = DispatchQueue(label: "com.macparakeet.camera-activity")

    private var stateHandler: StateHandler?
    private var deviceListListener: CMIOObjectPropertyListenerBlock?
    private var deviceListeners: [DeviceListener] = []

    public init() {}

    public func start(handler: @escaping StateHandler) {
        let currentDeviceIDs = Self.deviceIDs()
        lock.withLock {
            stateHandler = handler
            installDeviceListListenerLocked()
            refreshDeviceListenersLocked(deviceIDs: currentDeviceIDs)
        }
        emitCurrentState()
    }

    public func stop() {
        lock.withLock {
            removeDeviceListenersLocked()
            removeDeviceListListenerLocked()
            stateHandler = nil
        }
    }

    public func cameraRunning() -> Bool {
        Self.currentCameraRunning()
    }

    public static func currentCameraRunning() -> Bool {
        cameraRunning(deviceStates: deviceIDs().map(deviceRunningSomewhere))
    }

    public static func cameraRunning(deviceStates: [Bool]) -> Bool {
        deviceStates.contains(true)
    }

    private func handleDeviceListChanged() {
        let currentDeviceIDs = Self.deviceIDs()
        lock.withLock {
            refreshDeviceListenersLocked(deviceIDs: currentDeviceIDs)
        }
        emitCurrentState()
    }

    private func emitCurrentState() {
        let isRunning = cameraRunning()
        let handler = lock.withLock { stateHandler }
        handler?(isRunning)
    }

    private func installDeviceListListenerLocked() {
        guard deviceListListener == nil else { return }
        var address = Self.address(selector: kCMIOHardwarePropertyDevices)
        let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDeviceListChanged()
        }
        let status = CMIOObjectAddPropertyListenerBlock(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            listenerQueue,
            block
        )
        guard status == noErr else {
            logger.debug("camera_device_list_listener_failed status=\(status)")
            return
        }
        deviceListListener = block
    }

    private func removeDeviceListListenerLocked() {
        guard let block = deviceListListener else { return }
        var address = Self.address(selector: kCMIOHardwarePropertyDevices)
        CMIOObjectRemovePropertyListenerBlock(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            listenerQueue,
            block
        )
        deviceListListener = nil
    }

    private func refreshDeviceListenersLocked(deviceIDs: [CMIOObjectID]) {
        removeDeviceListenersLocked()

        for deviceID in deviceIDs {
            installDeviceListenerLocked(deviceID: deviceID)
        }
    }

    private func installDeviceListenerLocked(deviceID: CMIOObjectID) {
        var address = Self.address(selector: kCMIODevicePropertyDeviceIsRunningSomewhere)
        let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.emitCurrentState()
        }
        let status = CMIOObjectAddPropertyListenerBlock(deviceID, &address, listenerQueue, block)
        guard status == noErr else { return }
        deviceListeners.append(DeviceListener(deviceID: deviceID, block: block))
    }

    private func removeDeviceListenersLocked() {
        for listener in deviceListeners {
            var address = Self.address(selector: kCMIODevicePropertyDeviceIsRunningSomewhere)
            CMIOObjectRemovePropertyListenerBlock(
                listener.deviceID,
                &address,
                listenerQueue,
                listener.block
            )
        }
        deviceListeners.removeAll()
    }

    private static func deviceIDs() -> [CMIOObjectID] {
        var address = address(selector: kCMIOHardwarePropertyDevices)
        var dataSize: UInt32 = 0
        var status = CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        guard count > 0 else { return [] }

        var deviceIDs = [CMIOObjectID](repeating: 0, count: count)
        var dataUsed: UInt32 = 0
        status = deviceIDs.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return noErr }
            return CMIOObjectGetPropertyData(
                CMIOObjectID(kCMIOObjectSystemObject),
                &address,
                0,
                nil,
                dataSize,
                &dataUsed,
                baseAddress
            )
        }
        guard status == noErr else { return [] }

        let usedCount = min(count, Int(dataUsed) / MemoryLayout<CMIOObjectID>.size)
        return Array(deviceIDs.prefix(usedCount)).filter { $0 != kCMIOObjectUnknown }
    }

    private static func deviceRunningSomewhere(deviceID: CMIOObjectID) -> Bool {
        var address = address(selector: kCMIODevicePropertyDeviceIsRunningSomewhere)
        var value: UInt32 = 0
        var dataUsed: UInt32 = 0
        let status = CMIOObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &dataUsed,
            &value
        )
        guard status == noErr, dataUsed == UInt32(MemoryLayout<UInt32>.size) else { return false }
        return value != 0
    }

    private static func address(selector: Int) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(selector),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }
}
