#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// LS-465：Swift 接不住 `XCUIApplication.launch()` 啟動逾時丟出的 Objective-C 例外（XCTest 以例外中止測試方法），
/// 所以用最小的 `@try/@catch` 包一層；回傳 `YES` 代表 block 丟了例外並已吞下。
BOOL LSCatchObjCException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
