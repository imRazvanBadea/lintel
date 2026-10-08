// Lintel's Now Playing bridge.
//
// Since macOS 15.4 the private MediaRemote framework only answers entitled / platform processes,
// so Lintel loads this tiny library into /usr/bin/perl (a platform binary) and talks to it over pipes:
//   stdout: one JSON object per line describing the system-wide now-playing state (+ up next)
//   stdin:  "toggle" | "next" | "prev"      (EOF => exit, so it never outlives Lintel)
#import <AppKit/AppKit.h>
#include <dlfcn.h>

typedef void (*MRGetInfo)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*MRGetBool)(dispatch_queue_t, void (^)(BOOL));
typedef void (*MRGetPID)(dispatch_queue_t, void (^)(int));
typedef void (*MRRegister)(dispatch_queue_t);
typedef BOOL (*MRSendCommand)(int, NSDictionary *);
typedef id (*MRQueueRequestCreate)(long, long);
typedef void (*MRRequestQueue)(id, id, dispatch_queue_t, void (^)(id, NSError *));
typedef NSArray *(*MRQueueCopyItems)(id);

static MRGetInfo getInfo;
static MRGetBool getIsPlaying;
static MRGetPID getPID;
static MRSendCommand sendCommand;
static MRQueueRequestCreate queueRequestCreate;
static MRRequestQueue requestQueue;
static MRQueueCopyItems queueCopyItems;

static dispatch_queue_t workQ;
static NSString *lastArtworkKey;
static BOOL pending;

static void emit(NSDictionary *obj) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (!d) return;
    fwrite(d.bytes, 1, d.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

static id clean(id v) { return v ?: [NSNull null]; }

static void refresh(void) {
    pending = NO;
    getInfo(workQ, ^(NSDictionary *info) {
        getIsPlaying(workQ, ^(BOOL playing) {
            getPID(workQ, ^(int pid) {
                NSString *bundle = @"";
                if (pid > 0) {
                    // Resolve the bundle id of the playing app from its pid.
                    bundle = [NSRunningApplication runningApplicationWithProcessIdentifier:pid].bundleIdentifier ?: @"";
                }
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                out[@"bundle"] = bundle;
                out[@"pid"] = @(pid);
                out[@"playing"] = @(playing);
                out[@"title"] = clean(info[@"kMRMediaRemoteNowPlayingInfoTitle"]);
                out[@"artist"] = clean(info[@"kMRMediaRemoteNowPlayingInfoArtist"]);
                out[@"album"] = clean(info[@"kMRMediaRemoteNowPlayingInfoAlbum"]);
                out[@"duration"] = clean(info[@"kMRMediaRemoteNowPlayingInfoDuration"]);
                out[@"elapsed"] = clean(info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"]);
                out[@"rate"] = clean(info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"]);
                NSDate *ts = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
                out[@"timestamp"] = ts ? @([ts timeIntervalSince1970]) : [NSNull null];
                out[@"shuffle"] = clean(info[@"kMRMediaRemoteNowPlayingInfoShuffleMode"]);

                NSString *artKey = info[@"kMRMediaRemoteNowPlayingInfoArtworkIdentifier"]
                    ?: [NSString stringWithFormat:@"%@|%@", info[@"kMRMediaRemoteNowPlayingInfoTitle"], info[@"kMRMediaRemoteNowPlayingInfoAlbum"]];
                out[@"artworkKey"] = artKey;
                NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                if (art.length && ![artKey isEqualToString:lastArtworkKey]) {
                    out[@"artwork"] = [art base64EncodedStringWithOptions:0];
                    lastArtworkKey = artKey;
                }

                // The real playback queue, when the app publishes one (Music does; web pages don't).
                id req = queueRequestCreate(0, 8);
                requestQueue(req, nil, workQ, ^(id queue, NSError *err) {
                    NSMutableArray *next = [NSMutableArray array];
                    NSString *current = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
                    BOOL passedCurrent = NO;
                    for (id item in (queue ? queueCopyItems(queue) : @[])) {
                        id md = [item valueForKey:@"metadata"];
                        NSString *t = [md valueForKey:@"title"] ?: @"";
                        NSString *a = [md valueForKey:@"trackArtistName"] ?: @"";
                        if (!passedCurrent) {
                            if ([t isEqualToString:current]) passedCurrent = YES;
                            continue;
                        }
                        [next addObject:@{@"t": t, @"a": a}];
                    }
                    out[@"queue"] = next;
                    emit(out);
                });
            });
        });
    });
}

static void scheduleRefresh(void) {
    if (pending) return;
    pending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_MSEC), workQ, ^{ refresh(); });
}

void lintel_np_run(void *perl, void *cv) {
    @autoreleasepool {
        void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
        if (!h) { emit(@{@"error": @"MediaRemote unavailable"}); return; }
        getInfo = (MRGetInfo)dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
        getIsPlaying = (MRGetBool)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        getPID = (MRGetPID)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationPID");
        sendCommand = (MRSendCommand)dlsym(h, "MRMediaRemoteSendCommand");
        queueRequestCreate = (MRQueueRequestCreate)dlsym(h, "MRPlaybackQueueRequestCreateDefaultWithRange");
        requestQueue = (MRRequestQueue)dlsym(h, "MRMediaRemoteRequestNowPlayingPlaybackQueueForPlayer");
        queueCopyItems = (MRQueueCopyItems)dlsym(h, "MRPlaybackQueueCopyContentItems");
        MRRegister reg = (MRRegister)dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
        if (!getInfo || !getIsPlaying || !getPID || !sendCommand || !reg || !queueRequestCreate || !requestQueue || !queueCopyItems) {
            emit(@{@"error": @"MediaRemote symbols missing"});
            return;
        }

        workQ = dispatch_queue_create("lintel.np", DISPATCH_QUEUE_SERIAL);
        reg(workQ);
        for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                                 @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                                 @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
                                 @"kMRNowPlayingPlaybackQueueChangedNotification"]) {
            [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:nil
                                                          usingBlock:^(NSNotification *n) { dispatch_async(workQ, ^{ scheduleRefresh(); }); }];
        }
        dispatch_async(workQ, ^{ refresh(); });

        // Commands from Lintel on stdin; EOF means Lintel quit.
        dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, workQ);
        __block NSMutableString *buf = [NSMutableString string];
        dispatch_source_set_event_handler(src, ^{
            char chunk[256];
            ssize_t n = read(STDIN_FILENO, chunk, sizeof chunk);
            if (n <= 0) exit(0);
            [buf appendString:[[NSString alloc] initWithBytes:chunk length:n encoding:NSUTF8StringEncoding] ?: @""];
            NSRange r;
            while ((r = [buf rangeOfString:@"\n"]).location != NSNotFound) {
                NSString *cmd = [buf substringToIndex:r.location];
                [buf deleteCharactersInRange:NSMakeRange(0, r.location + 1)];
                if ([cmd isEqualToString:@"toggle"]) sendCommand(2, nil);
                else if ([cmd isEqualToString:@"next"]) sendCommand(4, nil);
                else if ([cmd isEqualToString:@"prev"]) sendCommand(5, nil);
                else if ([cmd isEqualToString:@"refresh"]) refresh();
                else if ([cmd isEqualToString:@"artwork"]) { lastArtworkKey = nil; refresh(); }
                else if ([cmd hasPrefix:@"skip "]) {
                    // Jump to the Nth upcoming track by skipping forward (works for any player).
                    int n = MAX(1, MIN(20, [[cmd substringFromIndex:5] intValue]));
                    for (int i = 0; i < n; i++) { sendCommand(4, nil); usleep(180 * 1000); }
                }
                scheduleRefresh();
            }
        });
        dispatch_resume(src);
        CFRunLoopRun();
    }
}
