// CGVirtualDisplayPrivate.h — private CoreGraphics virtual display API.
//
// These classes ship inside CoreGraphics (macOS 11+) but are not in the
// public SDK. Declarations mirror the ones DeskPad / BetterDisplay use.
// Every interface is weak-imported so the app still launches on a system
// where the classes are missing; VirtualDisplay.swift checks
// NSClassFromString before touching them.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@class CGVirtualDisplay;

__attribute__((weak_import))
@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (copy, nonatomic, nullable) void (^terminationHandler)(id _Nullable, CGVirtualDisplay * _Nullable);
@end

__attribute__((weak_import))
@interface CGVirtualDisplayMode : NSObject
@property (readonly, nonatomic) CGFloat refreshRate;
@property (readonly, nonatomic) NSUInteger width;
@property (readonly, nonatomic) NSUInteger height;
- (instancetype)initWithWidth:(NSUInteger)width
                       height:(NSUInteger)height
                  refreshRate:(CGFloat)refreshRate;
@end

__attribute__((weak_import))
@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic) unsigned int hiDPI;
@end

__attribute__((weak_import))
@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) NSArray *modes;
@property (readonly, nonatomic) unsigned int hiDPI;
@property (readonly, nonatomic) CGDirectDisplayID displayID;
@property (readonly, nonatomic, nullable) id terminationHandler;
@property (readonly, nonatomic) dispatch_queue_t queue;
@property (readonly, nonatomic) unsigned int maxPixelsHigh;
@property (readonly, nonatomic) unsigned int maxPixelsWide;
@property (readonly, nonatomic) CGSize sizeInMillimeters;
@property (readonly, nonatomic) NSString *name;
@property (readonly, nonatomic) unsigned int serialNum;
@property (readonly, nonatomic) unsigned int productID;
@property (readonly, nonatomic) unsigned int vendorID;
- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

NS_ASSUME_NONNULL_END
