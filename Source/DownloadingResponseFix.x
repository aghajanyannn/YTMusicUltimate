#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "FFMpegDownloader.h"
#import "Headers/YTUIResources.h"
#import "Headers/YTMActionSheetController.h"
#import "Headers/YTMActionRowView.h"
#import "Headers/YTIPlayerOverlayRenderer.h"
#import "Headers/YTIPlayerOverlayActionSupportedRenderers.h"
#import "Headers/YTMNowPlayingViewController.h"
#import "Headers/YTPlayerView.h"
#import "Headers/YTIThumbnailDetails_Thumbnail.h"
#import "Headers/YTIFormatStream.h"
#import "Headers/YTAlertView.h"
#import "Headers/ELMNodeController.h"

static BOOL YTMU(NSString *key) {
    NSDictionary *YTMUltimateDict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:@"YTMUltimate"];
    return [YTMUltimateDict[key] boolValue];
}

@interface UIView ()
- (UIViewController *)_viewControllerForAncestor;
@end

static id YTMUSendObject(id object, SEL selector) {
    if (!object || ![object respondsToSelector:selector]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static id YTMUSafeValue(id object, NSString *key) {
    if (!object || key.length == 0) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *YTMUStringValue(id object, NSString *key) {
    id value = YTMUSafeValue(object, key);
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static long long YTMUNumberValue(id object, NSString *key) {
    id value = YTMUSafeValue(object, key);
    return [value respondsToSelector:@selector(longLongValue)] ? [value longLongValue] : 0;
}

static NSString *YTMUQueryValue(NSString *urlString, NSString *name) {
    if (urlString.length == 0 || name.length == 0) return nil;
    NSURLComponents *components = [NSURLComponents componentsWithString:urlString];
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:name]) return item.value;
    }
    return nil;
}

static YTPlayerResponse *YTMUResponseForPlayer(YTPlayerViewController *player) {
    if (!player) return nil;

    // Newer YouTube/YouTube Music builds can keep the stream-bearing response
    // in contentPlayerResponse while playerResponse contains only partial data.
    SEL contentSelector = NSSelectorFromString(@"contentPlayerResponse");
    id response = YTMUSendObject(player, contentSelector);
    if (response) return (YTPlayerResponse *)response;

    if ([player respondsToSelector:@selector(playerResponse)]) {
        return player.playerResponse;
    }
    return nil;
}

static BOOL YTMUAudioItag(long long itag) {
    switch (itag) {
        case 139:
        case 140:
        case 141:
        case 249:
        case 250:
        case 251:
            return YES;
        default:
            return NO;
    }
}

static NSString *YTMUAdaptiveAudioURL(YTPlayerResponse *response) {
    NSArray *formats = response.playerData.streamingData.adaptiveFormatsArray;
    if (![formats isKindOfClass:NSArray.class] || formats.count == 0) return nil;

    NSString *bestURL = nil;
    long long bestScore = -1;

    for (id stream in formats) {
        NSString *url = YTMUStringValue(stream, @"URL");
        if (url.length == 0) continue;

        NSString *mime = YTMUStringValue(stream, @"mimeType");
        if (mime.length == 0) mime = YTMUQueryValue(url, @"mime");
        NSString *lowerMime = mime.lowercaseString;

        long long itag = YTMUNumberValue(stream, @"itag");
        if (itag == 0) itag = [YTMUQueryValue(url, @"itag") longLongValue];

        NSString *qualityLabel = YTMUStringValue(stream, @"qualityLabel");
        long long bitrate = YTMUNumberValue(stream, @"bitrate");

        if ([lowerMime containsString:@"video/"]) continue;

        BOOL isAudio = [lowerMime containsString:@"audio/"] || YTMUAudioItag(itag);
        if (!isAudio && mime.length == 0 && qualityLabel.length == 0) isAudio = YES;
        if (!isAudio) continue;

        long long score = bitrate;
        if ([lowerMime containsString:@"audio/mp4"]) score += 3000000000000LL;
        if (itag == 140 || itag == 141 || itag == 139) score += 2000000000000LL;
        if ([lowerMime containsString:@"audio/"]) score += 1000000000000LL;
        if (YTMUAudioItag(itag)) score += 500000000000LL;

        if (score > bestScore) {
            bestScore = score;
            bestURL = url;
        }
    }

    return bestURL;
}

static YTPlayerViewController *YTMUPlayerFromCandidate(id candidate) {
    if (!candidate) return nil;

    if ([candidate respondsToSelector:@selector(playerResponse)] ||
        [candidate respondsToSelector:NSSelectorFromString(@"contentPlayerResponse")]) {
        return (YTPlayerViewController *)candidate;
    }

    NSArray<NSString *> *selectors = @[
        @"playerViewDelegate",
        @"playerViewController",
        @"playerController",
        @"playerView"
    ];

    for (NSString *selectorName in selectors) {
        id next = YTMUSendObject(candidate, NSSelectorFromString(selectorName));
        if (!next || next == candidate) continue;

        if ([next respondsToSelector:@selector(playerResponse)] ||
            [next respondsToSelector:NSSelectorFromString(@"contentPlayerResponse")]) {
            return (YTPlayerViewController *)next;
        }

        id delegate = YTMUSendObject(next, NSSelectorFromString(@"playerViewDelegate"));
        if (delegate && ([delegate respondsToSelector:@selector(playerResponse)] ||
                         [delegate respondsToSelector:NSSelectorFromString(@"contentPlayerResponse")])) {
            return (YTPlayerViewController *)delegate;
        }
    }

    return nil;
}

static YTPlayerViewController *YTMUFindPlayerInView(UIView *view) {
    if (!view) return nil;

    YTPlayerViewController *player = YTMUPlayerFromCandidate(view);
    if (player) return player;

    for (UIView *subview in view.subviews) {
        player = YTMUFindPlayerInView(subview);
        if (player) return player;
    }

    return nil;
}

static YTPlayerViewController *YTMUFindPlayerInController(UIViewController *controller, NSMutableSet *visited) {
    if (!controller) return nil;

    NSValue *key = [NSValue valueWithNonretainedObject:controller];
    if ([visited containsObject:key]) return nil;
    [visited addObject:key];

    YTPlayerViewController *player = YTMUPlayerFromCandidate(controller);
    if (player) return player;

    player = YTMUFindPlayerInView(controller.view);
    if (player) return player;

    for (UIViewController *child in controller.childViewControllers) {
        player = YTMUFindPlayerInController(child, visited);
        if (player) return player;
    }

    return nil;
}

static YTPlayerViewController *YTMUResolvePlayerController(UIViewController *playingVC) {
    NSMutableSet *visited = [NSMutableSet set];

    UIViewController *cursor = playingVC;
    while (cursor) {
        YTPlayerViewController *player = YTMUFindPlayerInController(cursor, visited);
        if (player) return player;
        cursor = cursor.parentViewController;
    }

    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive) continue;
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *candidateWindow in ((UIWindowScene *)scene).windows) {
            if (candidateWindow.isKeyWindow) {
                window = candidateWindow;
                break;
            }
        }
        if (window) break;
    }

    if (!window) window = UIApplication.sharedApplication.keyWindow;

    YTPlayerViewController *player = YTMUFindPlayerInController(window.rootViewController, visited);
    if (player) return player;

    return YTMUFindPlayerInView(window);
}

static void YTMUShowDownloadError(void) {
    YTAlertView *alertView = [%c(YTAlertView) infoDialog];
    alertView.title = LOC(@"OOPS");
    alertView.subtitle = LOC(@"LINK_NOT_FOUND");
    [alertView show];
}

@interface ELMTouchCommandPropertiesHandler : NSObject
- (void)downloadAudio:(YTPlayerViewController *)playerVC;
- (void)downloadCoverImage:(YTPlayerViewController *)playerVC;
- (NSString *)getURLFromManifest:(NSURL *)manifest;
@end

%hook ELMTouchCommandPropertiesHandler
- (void)handleTap {
    if (class_getInstanceVariable([self class], "_controller") == NULL) return %orig;
    if (class_getInstanceVariable([self class], "_tapRecognizer") == NULL) return %orig;

    ELMNodeController *node = [self valueForKey:@"_controller"];
    UIGestureRecognizer *tapRecognizer = [self valueForKey:@"_tapRecognizer"];

    if (![node.key isEqualToString:@"music_download_badge_1"]) return %orig;

    UIViewController *ancestor = tapRecognizer.view._viewControllerForAncestor;
    if (![ancestor isKindOfClass:%c(YTMNowPlayingViewController)]) return %orig;

    YTMNowPlayingViewController *playingVC = (YTMNowPlayingViewController *)ancestor;
    YTPlayerViewController *playerVC = YTMUResolvePlayerController(playingVC);

    YTPlayerResponse *response = YTMUResponseForPlayer(playerVC);
    if (!playerVC || !response) {
        YTMUShowDownloadError();
        return;
    }

    YTMActionSheetController *sheetController = [%c(YTMActionSheetController) musicActionSheetController];
    sheetController.sourceView = tapRecognizer.view;
    [sheetController addHeaderWithTitle:LOC(@"SELECT_ACTION") subtitle:nil];

    [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"DOWNLOAD_AUDIO") iconImage:[%c(YTUIResources) audioOutline] style:0 handler:^ {
        [self downloadAudio:playerVC];
    }]];

    [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"DOWNLOAD_COVER") iconImage:[%c(YTUIResources) outlineImageWithColor:[UIColor whiteColor]] style:0 handler:^ {
        [self downloadCoverImage:playerVC];
    }]];

    [sheetController addAction:[%c(YTActionSheetAction) actionWithTitle:LOC(@"DOWNLOAD_PREMIUM") iconImage:[%c(YTUIResources) downloadOutline] secondaryIconImage:[%c(YTUIResources) youtubePremiumBadgeLight] accessibilityIdentifier:nil handler:^ {
        return %orig;
    }]];

    if (YTMU(@"downloadAudio") && YTMU(@"downloadCoverImage")) {
        [sheetController presentFromViewController:playingVC animated:YES completion:nil];
    } else if (YTMU(@"downloadAudio")) {
        [self downloadAudio:playerVC];
    } else if (YTMU(@"downloadCoverImage")) {
        [self downloadCoverImage:playerVC];
    }
}

%new
- (void)downloadAudio:(YTPlayerViewController *)playerVC {
    YTPlayerResponse *response = YTMUResponseForPlayer(playerVC);
    if (!playerVC || !response) {
        YTMUShowDownloadError();
        return;
    }

    NSString *title = [response.playerData.videoDetails.title stringByReplacingOccurrencesOfString:@"/" withString:@""];
    NSString *author = [response.playerData.videoDetails.author stringByReplacingOccurrencesOfString:@"/" withString:@""];

    FFMpegDownloader *ffmpeg = [[FFMpegDownloader alloc] init];
    ffmpeg.tempName = playerVC.contentVideoID;
    ffmpeg.mediaName = [NSString stringWithFormat:@"%@ - %@", author ?: @"", title ?: @""];
    ffmpeg.duration = round(playerVC.currentVideoTotalMediaTime);

    NSString *audioURL = nil;
    NSString *manifestURL = response.playerData.streamingData.hlsManifestURL;
    if (manifestURL.length > 0) {
        audioURL = [self getURLFromManifest:[NSURL URLWithString:manifestURL]];
    }
    if (audioURL.length == 0) {
        audioURL = YTMUAdaptiveAudioURL(response);
    }

    if (audioURL.length == 0) {
        YTMUShowDownloadError();
        return;
    }

    [ffmpeg downloadAudio:audioURL];

    NSMutableArray *thumbnailsArray = response.playerData.videoDetails.thumbnail.thumbnailsArray;
    YTIThumbnailDetails_Thumbnail *thumbnail = [thumbnailsArray lastObject];
    if (thumbnail.URL.length > 0) {
        NSData *imageData = [NSData dataWithContentsOfURL:[NSURL URLWithString:thumbnail.URL]];
        if (imageData) {
            NSURL *documentsURL = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] lastObject];
            NSURL *folderURL = [documentsURL URLByAppendingPathComponent:@"YTMusicUltimate"];
            [[NSFileManager defaultManager] createDirectoryAtURL:folderURL withIntermediateDirectories:YES attributes:nil error:nil];
            NSURL *coverURL = [folderURL URLByAppendingPathComponent:[NSString stringWithFormat:@"%@ - %@.png", author ?: @"", title ?: @""]];
            [imageData writeToURL:coverURL atomically:YES];
        }
    }
}

%new
- (NSString *)getURLFromManifest:(NSURL *)manifest {
    if (!manifest) return nil;

    NSData *manifestData = [NSData dataWithContentsOfURL:manifest];
    if (!manifestData) return nil;

    NSString *manifestString = [[NSString alloc] initWithData:manifestData encoding:NSUTF8StringEncoding];
    if (!manifestString) return nil;

    NSArray *manifestLines = [manifestString componentsSeparatedByString:@"\n"];
    NSArray *groupIDS = @[@"234", @"233"];

    for (NSString *groupID in groupIDS) {
        for (NSString *line in manifestLines) {
            NSString *searchString = [NSString stringWithFormat:@"TYPE=AUDIO,GROUP-ID=\"%@\"", groupID];
            if ([line containsString:searchString]) {
                NSRange startRange = [line rangeOfString:@"https://"];
                NSRange endRange = [line rangeOfString:@"index.m3u8"];
                if (startRange.location != NSNotFound && endRange.location != NSNotFound) {
                    NSRange targetRange = NSMakeRange(startRange.location, NSMaxRange(endRange) - startRange.location);
                    return [line substringWithRange:targetRange];
                }
            }
        }
    }

    return nil;
}

%new
- (void)downloadCoverImage:(YTPlayerViewController *)playerVC {
    YTPlayerResponse *response = YTMUResponseForPlayer(playerVC);
    if (!playerVC || !response) {
        YTMUShowDownloadError();
        return;
    }

    NSMutableArray *thumbnailsArray = response.playerData.videoDetails.thumbnail.thumbnailsArray;
    YTIThumbnailDetails_Thumbnail *thumbnail = [thumbnailsArray lastObject];
    if (!thumbnail || thumbnail.URL.length == 0) {
        YTMUShowDownloadError();
        return;
    }

    MBProgressHUD *hud = [MBProgressHUD showHUDAddedTo:[UIApplication sharedApplication].keyWindow animated:YES];
    hud.mode = MBProgressHUDModeIndeterminate;

    NSString *thumbnailURL = [thumbnail.URL stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"w%u-h%u-", thumbnail.width, thumbnail.width] withString:@"w2048-h2048-"];

    FFMpegDownloader *ffmpeg = [[FFMpegDownloader alloc] init];
    [ffmpeg downloadImage:[NSURL URLWithString:thumbnailURL]];

    [hud hideAnimated:YES];
}
%end
