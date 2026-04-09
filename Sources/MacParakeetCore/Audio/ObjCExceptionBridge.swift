import Foundation
import MacParakeetObjCShims

/// Runs `block` inside an Objective-C `@try`/`@catch` trampoline. If `block`
/// raises an `NSException`, the exception is caught and rethrown as a Swift
/// `NSError` in the `MPKObjCExceptionErrorDomain` domain. This is the only
/// reliable way to recover from Objective-C exceptions raised by AppKit,
/// AVFoundation, Core Audio, etc. — Swift's native `do/try/catch` cannot catch
/// them and the runtime will call `abort()` as soon as one reaches a Swift frame.
///
/// Keep the block as small as possible — only the call that may raise should
/// run inside it.
@discardableResult
func catchingObjCException<T>(_ block: () throws -> T) throws -> T {
    var result: Result<T, Error>?
    var objcError: NSError?
    let ok = MPKTryBlock({
        do {
            result = .success(try block())
        } catch {
            result = .failure(error)
        }
    }, &objcError)

    if !ok {
        throw objcError ?? NSError(
            domain: MPKObjCExceptionErrorDomain,
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "Unknown Objective-C exception"]
        )
    }

    switch result {
    case .success(let value):
        return value
    case .failure(let error):
        throw error
    case .none:
        // MPKTryBlock returned YES without calling our inner assignment — should
        // be unreachable, but be explicit rather than force-unwrapping.
        throw NSError(
            domain: MPKObjCExceptionErrorDomain,
            code: 0,
            userInfo: [NSLocalizedDescriptionKey: "catchingObjCException produced no result"]
        )
    }
}
