#import "LSExceptionCatcher.h"

BOOL LSCatchObjCException(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return NO;
    } @catch (NSException *exception) {
        return YES;
    }
}
