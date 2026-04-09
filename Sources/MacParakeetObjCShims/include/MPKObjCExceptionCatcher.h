#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Domain used for `NSError` values produced when an Objective-C `NSException`
/// is caught by `MPKTryBlock`.
FOUNDATION_EXPORT NSErrorDomain const MPKObjCExceptionErrorDomain;

/// Keys populated on the `NSError.userInfo` dictionary when an exception is caught.
FOUNDATION_EXPORT NSString *const MPKObjCExceptionNameKey;
FOUNDATION_EXPORT NSString *const MPKObjCExceptionReasonKey;
FOUNDATION_EXPORT NSString *const MPKObjCExceptionUserInfoKey;
FOUNDATION_EXPORT NSString *const MPKObjCExceptionCallStackKey;

/// Executes @c block inside an Objective-C @c \@try / @c \@catch trampoline.
///
/// Swift's native @c do / @c try / @c catch cannot catch Objective-C
/// @c NSException values — the Swift runtime will call @c abort() as soon as
/// one propagates through a Swift frame. This helper lets Swift callers convert
/// an @c NSException raised by AppKit / AVFoundation / Core Audio / etc. into a
/// throwable @c NSError so it can be handled on the Swift side.
///
/// @param block The block to execute. May raise an @c NSException.
/// @param error Out-parameter populated with a non-nil @c NSError if @c block
///              raised. Unchanged on success.
/// @return @c YES if @c block returned normally, @c NO if it raised.
FOUNDATION_EXPORT BOOL MPKTryBlock(NS_NOESCAPE void (^block)(void),
                                   NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
