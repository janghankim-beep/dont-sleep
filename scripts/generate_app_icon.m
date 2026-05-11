#import <Cocoa/Cocoa.h>

static NSImage *DSLoadSourceImage(NSURL *sourceURL) {
    NSImage *image = [[NSImage alloc] initWithContentsOfURL:sourceURL];
    if (image == nil || image.size.width <= 0.0 || image.size.height <= 0.0) {
        [NSException raise:@"IconSourceError" format:@"Could not load %@", sourceURL.path];
    }

    return image;
}

static NSRect DSAspectFillRect(NSSize sourceSize, NSRect targetRect) {
    CGFloat scale = MAX(targetRect.size.width / sourceSize.width, targetRect.size.height / sourceSize.height);
    NSSize drawSize = NSMakeSize(sourceSize.width * scale, sourceSize.height * scale);
    CGFloat x = NSMidX(targetRect) - drawSize.width / 2.0;
    CGFloat y = NSMidY(targetRect) - drawSize.height / 2.0;
    return NSMakeRect(x, y, drawSize.width, drawSize.height);
}

static NSData *DSPNGDataForIcon(NSUInteger pixelSize, NSImage *sourceImage) {
    NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                       pixelsWide:pixelSize
                                                                       pixelsHigh:pixelSize
                                                                    bitsPerSample:8
                                                                  samplesPerPixel:4
                                                                         hasAlpha:YES
                                                                         isPlanar:NO
                                                                   colorSpaceName:NSCalibratedRGBColorSpace
                                                                      bytesPerRow:0
                                                                     bitsPerPixel:0];
    bitmap.size = NSMakeSize((CGFloat)pixelSize, (CGFloat)pixelSize);

    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:context];
    context.imageInterpolation = NSImageInterpolationHigh;

    CGFloat size = (CGFloat)pixelSize;
    NSRect canvas = NSMakeRect(0.0, 0.0, size, size);
    NSBezierPath *roundedIcon = [NSBezierPath bezierPathWithRoundedRect:canvas
                                                                xRadius:size * 0.22
                                                                yRadius:size * 0.22];

    [NSGraphicsContext saveGraphicsState];
    [roundedIcon addClip];
    NSRect drawRect = DSAspectFillRect(sourceImage.size, canvas);
    [sourceImage drawInRect:drawRect
                   fromRect:NSZeroRect
                  operation:NSCompositingOperationSourceOver
                   fraction:1.0
             respectFlipped:NO
                      hints:nil];
    [NSGraphicsContext restoreGraphicsState];

    roundedIcon.lineWidth = MAX(1.0, size * 0.006);
    [[NSColor colorWithCalibratedWhite:1.0 alpha:0.18] setStroke];
    [roundedIcon stroke];

    [NSGraphicsContext restoreGraphicsState];

    return [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

static void DSWritePNGData(NSData *pngData, NSURL *url) {
    if (![pngData writeToURL:url atomically:YES]) {
        [NSException raise:@"IconWriteError" format:@"Could not write %@", url.path];
    }
}

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;

    @autoreleasepool {
        NSFileManager *fileManager = NSFileManager.defaultManager;
        NSURL *rootURL = [NSURL fileURLWithPath:fileManager.currentDirectoryPath isDirectory:YES];
        NSURL *buildURL = [rootURL URLByAppendingPathComponent:@".build" isDirectory:YES];
        NSURL *iconsetURL = [buildURL URLByAppendingPathComponent:@"AppIcon.iconset" isDirectory:YES];
        NSURL *sourceURL = [rootURL URLByAppendingPathComponent:@"assets/app-icon-source.png"];
        NSURL *outputURL = [rootURL URLByAppendingPathComponent:@"Resources/AppIcon.icns"];
        NSURL *previewURL = [rootURL URLByAppendingPathComponent:@"assets/app-icon.png"];
        NSImage *sourceImage = DSLoadSourceImage(sourceURL);

        [fileManager removeItemAtURL:iconsetURL error:nil];
        [fileManager createDirectoryAtURL:iconsetURL withIntermediateDirectories:YES attributes:nil error:nil];
        [fileManager createDirectoryAtURL:outputURL.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        [fileManager createDirectoryAtURL:previewURL.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];

        NSArray<NSDictionary<NSString *, id> *> *specs = @[
            @{@"base": @16, @"scale": @1, @"name": @"icon_16x16.png"},
            @{@"base": @16, @"scale": @2, @"name": @"icon_16x16@2x.png"},
            @{@"base": @32, @"scale": @1, @"name": @"icon_32x32.png"},
            @{@"base": @32, @"scale": @2, @"name": @"icon_32x32@2x.png"},
            @{@"base": @128, @"scale": @1, @"name": @"icon_128x128.png"},
            @{@"base": @128, @"scale": @2, @"name": @"icon_128x128@2x.png"},
            @{@"base": @256, @"scale": @1, @"name": @"icon_256x256.png"},
            @{@"base": @256, @"scale": @2, @"name": @"icon_256x256@2x.png"},
            @{@"base": @512, @"scale": @1, @"name": @"icon_512x512.png"},
            @{@"base": @512, @"scale": @2, @"name": @"icon_512x512@2x.png"}
        ];

        for (NSDictionary<NSString *, id> *spec in specs) {
            NSUInteger base = [spec[@"base"] unsignedIntegerValue];
            NSUInteger scale = [spec[@"scale"] unsignedIntegerValue];
            NSString *name = spec[@"name"];
            DSWritePNGData(DSPNGDataForIcon(base * scale, sourceImage), [iconsetURL URLByAppendingPathComponent:name]);
        }

        DSWritePNGData(DSPNGDataForIcon(1024, sourceImage), previewURL);

        NSTask *task = [[NSTask alloc] init];
        task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/iconutil"];
        task.arguments = @[@"-c", @"icns", iconsetURL.path, @"-o", outputURL.path];
        [task launch];
        [task waitUntilExit];

        if (task.terminationStatus != 0) {
            [NSException raise:@"IconUtilError" format:@"iconutil failed with status %d", task.terminationStatus];
        }

        printf("%s\n", outputURL.path.UTF8String);
    }

    return 0;
}
