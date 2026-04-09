#import "MPKObjCExceptionCatcher.h"

NSErrorDomain const MPKObjCExceptionErrorDomain = @"com.macparakeet.objc-exception";

NSString *const MPKObjCExceptionNameKey = @"MPKObjCExceptionName";
NSString *const MPKObjCExceptionReasonKey = @"MPKObjCExceptionReason";
NSString *const MPKObjCExceptionUserInfoKey = @"MPKObjCExceptionUserInfo";
NSString *const MPKObjCExceptionCallStackKey = @"MPKObjCExceptionCallStack";

BOOL MPKTryBlock(NS_NOESCAPE void (^block)(void),
                 NSError * _Nullable * _Nullable error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            NSMutableDictionary<NSErrorUserInfoKey, id> *userInfo = [NSMutableDictionary dictionary];

            NSString *name = exception.name ?: @"NSException";
            NSString *reason = exception.reason ?: @"(no reason)";
            userInfo[NSLocalizedDescriptionKey] =
                [NSString stringWithFormat:@"%@: %@", name, reason];
            userInfo[MPKObjCExceptionNameKey] = name;
            userInfo[MPKObjCExceptionReasonKey] = reason;
            if (exception.userInfo != nil) {
                userInfo[MPKObjCExceptionUserInfoKey] = exception.userInfo;
            }
            NSArray<NSString *> *callStack = exception.callStackSymbols;
            if (callStack != nil) {
                userInfo[MPKObjCExceptionCallStackKey] = callStack;
            }

            *error = [NSError errorWithDomain:MPKObjCExceptionErrorDomain
                                         code:0
                                     userInfo:userInfo];
        }
        return NO;
    }
}
