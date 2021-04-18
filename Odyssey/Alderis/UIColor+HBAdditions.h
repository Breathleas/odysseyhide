#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// UIColor (HBAdditions) is a class category in `Cephei` that provides some convenience methods.
@interface UIColor (HBColorPickerAdditions)

/// Initializes and returns a color object using data from the specified object.
///
/// The value is expected to be one of:
///
/// * An array of 3 or 4 integer RGB or RGBA color components, with values between 0 and 255 (e.g.
///   `@[ 218, 192, 222 ]`)
/// * A CSS-style hex string, with an optional alpha component (e.g. `#DAC0DE` or `#DACODE55`)
/// * A short CSS-style hex string, with an optional alpha component (e.g. `#DC0` or `#DC05`)
///
/// @param value The object to retrieve data from. See the discussion for the supported object
/// types.
/// @returns An initialized color object. The color information represented by this object is in the
/// device RGB colorspace.
- (nullable instancetype)initWithHbcp_propertyListValue:(id)value;

- (NSString *)hbcp_propertyListValue;

@end

NS_ASSUME_NONNULL_END
