// SPDX-FileCopyrightText: 2026 Niels Franke
// SPDX-License-Identifier: MIT
//
// ContactSheet — Capture One publish plugin (principal class).
//
// Capture One renders the selected variants to temp JPEGs per -processingSettingsForAction:, then
// hands their paths to -startPublishingTask:…, which multipart-POSTs them to a ContactSheet gallery
// (Authorization: Bearer cs_pat_…). The Plugin-Manager settings (instance URL / API token / gallery)
// are provided via the COSettings protocol and persisted in a private NSUserDefaults suite.

#import <Cocoa/Cocoa.h>
#import <CaptureOnePlugins/CaptureOnePlugins.h>

static NSString * const kSuite = @"com.nielsfranke.contactsheet.captureone";
static NSString * const kURL = @"instanceURL";
static NSString * const kToken = @"apiToken";
static NSString * const kGalleryId = @"galleryId";
static NSString * const kGalleries = @"galleries"; // cached [{id,name,share_token}]
static NSString * const kNewGallery = @"newGalleryName"; // Plugin-Manager "create gallery" field

static NSError *CSError(NSString *msg) {
    return [NSError errorWithDomain:@"ContactSheet" code:1 userInfo:@{ NSLocalizedDescriptionKey: msg }];
}

// A settings/dict value arrives typed as id<NSSecureCoding> (no -isKindOfClass:); coerce to NSString.
static NSString *CSStr(id value) {
    return [value isKindOfClass:NSString.class] ? (NSString *)value : nil;
}

// Flatten the gallery tree (children) into a display list, indenting nested galleries by path.
static void CSFlatten(NSArray *nodes, NSString *prefix, NSMutableArray *out) {
    for (NSDictionary *g in nodes) {
        if (![g isKindOfClass:NSDictionary.class]) continue;
        NSString *name = [g[@"name"] isKindOfClass:NSString.class] ? g[@"name"] : @"(unnamed)";
        NSString *display = prefix.length ? [NSString stringWithFormat:@"%@ / %@", prefix, name] : name;
        NSString *gid = g[@"id"];
        if ([gid isKindOfClass:NSString.class]) {
            NSString *share = [g[@"share_token"] isKindOfClass:NSString.class] ? g[@"share_token"] : @"";
            [out addObject:@{ @"id": gid, @"name": display, @"share_token": share }];
        }
        if ([g[@"children"] isKindOfClass:NSArray.class]) CSFlatten(g[@"children"], display, out);
    }
}

#pragma mark - Synchronous upload with progress

@interface CSUploader : NSObject <NSURLSessionTaskDelegate>
@property (nonatomic, weak) COPluginTask *task;
@property (nonatomic, copy) COPluginTaskProgress progress;
@end

@implementation CSUploader {
    NSInteger _status;
    NSError *_error;
    dispatch_semaphore_t _sem;
}

// Runs the upload synchronously (startPublishingTask is a synchronous, background call). Returns the
// HTTP status code, or -1 on a transport error (in *error). Reports byte progress along the way.
- (NSInteger)uploadRequest:(NSURLRequest *)req body:(NSData *)body error:(NSError **)error {
    _sem = dispatch_semaphore_create(0);
    NSURLSession *session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration
                                                          delegate:self delegateQueue:nil];
    NSURLSessionUploadTask *t = [session uploadTaskWithRequest:req fromData:body
                                            completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        self->_status = [r isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)r).statusCode : 0;
        self->_error = e;
        dispatch_semaphore_signal(self->_sem);
    }];
    [t resume];
    dispatch_semaphore_wait(_sem, DISPATCH_TIME_FOREVER);
    [session finishTasksAndInvalidate];
    if (_error) { if (error) *error = _error; return -1; }
    return _status;
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)t
   didSendBodyData:(int64_t)bytesSent totalBytesSent:(int64_t)total
totalBytesExpectedToSend:(int64_t)expected {
    if (self.task.cancelled) { [t cancel]; return; }
    if (self.progress) self.progress(self.task, (NSUInteger)total, (NSUInteger)MAX(expected, total), @"Uploading to ContactSheet…");
}
@end

#pragma mark - Plugin

@interface CSContactSheetPlugin : COPluginBase <COPublishingPlugin, COActionSettings, COSettings>
@end

@implementation CSContactSheetPlugin

- (NSUserDefaults *)defaults {
    return [[NSUserDefaults alloc] initWithSuiteName:kSuite];
}

- (NSString *)baseURL {
    NSString *u = [[[self defaults] stringForKey:kURL] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    while ([u hasSuffix:@"/"]) u = [u substringToIndex:u.length - 1];
    return u ?: @"";
}

- (NSString *)publicURLForGallery:(NSString *)galleryId base:(NSString *)base {
    for (NSDictionary *g in [[self defaults] arrayForKey:kGalleries]) {
        if ([g[@"id"] isEqual:galleryId]) {
            NSString *share = g[@"share_token"];
            if ([share isKindOfClass:NSString.class] && share.length) return [NSString stringWithFormat:@"%@/g/%@", base, share];
        }
    }
    return base;
}

// GET /api/galleries with the token → flattened [{id,name,share_token}], or nil + *error.
- (NSArray *)fetchGalleriesWithError:(NSError **)error {
    NSString *base = [self baseURL];
    NSString *token = [[self defaults] stringForKey:kToken];
    if (!base.length || !token.length) { if (error) *error = CSError(@"Enter the instance URL and API token first."); return nil; }
    NSURL *url = [NSURL URLWithString:[base stringByAppendingString:@"/api/galleries"]];
    if (!url) { if (error) *error = CSError(@"The instance URL is not valid."); return nil; }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    req.timeoutInterval = 20;

    __block NSData *data; __block NSURLResponse *resp; __block NSError *err;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        data = d; resp = r; err = e; dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

    if (err) { if (error) *error = CSError([@"Network error: " stringByAppendingString:err.localizedDescription]); return nil; }
    NSInteger code = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
    if (code == 401) { if (error) *error = CSError(@"Unauthorized — check the API token."); return nil; }
    if (code < 200 || code >= 300) { if (error) *error = CSError([NSString stringWithFormat:@"Server returned HTTP %ld.", (long)code]); return nil; }

    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![json isKindOfClass:NSArray.class]) { if (error) *error = CSError(@"Unexpected response from the server."); return nil; }
    NSMutableArray *flat = [NSMutableArray array];
    CSFlatten(json, @"", flat);
    if (flat.count == 0) { if (error) *error = CSError(@"No galleries found for this token."); return nil; }
    return flat;
}

// POST /api/galleries → the new gallery dict {id,name,share_token}, appended to the cache. nil + *error.
- (NSDictionary *)createGalleryNamed:(NSString *)name error:(NSError **)error {
    NSString *base = [self baseURL];
    NSString *token = [[self defaults] stringForKey:kToken];
    if (!base.length || !token.length) { if (error) *error = CSError(@"Enter the instance URL and API token first."); return nil; }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[base stringByAppendingString:@"/api/galleries"]]];
    req.HTTPMethod = @"POST";
    [req setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{ @"name": name, @"mode": @"presentation" } options:0 error:nil];
    req.timeoutInterval = 20;

    __block NSData *data; __block NSURLResponse *resp; __block NSError *err;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        data = d; resp = r; err = e; dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

    if (err) { if (error) *error = CSError([@"Network error: " stringByAppendingString:err.localizedDescription]); return nil; }
    NSInteger code = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
    if (code == 403) { if (error) *error = CSError(@"The token lacks the galleries:write permission."); return nil; }
    if (code < 200 || code >= 300) { if (error) *error = CSError([NSString stringWithFormat:@"Could not create gallery (HTTP %ld).", (long)code]); return nil; }

    NSDictionary *g = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![g isKindOfClass:NSDictionary.class] || ![g[@"id"] isKindOfClass:NSString.class]) {
        if (error) *error = CSError(@"Unexpected response creating the gallery."); return nil;
    }
    NSDictionary *entry = @{
        @"id": g[@"id"],
        @"name": [g[@"name"] isKindOfClass:NSString.class] ? g[@"name"] : name,
        @"share_token": [g[@"share_token"] isKindOfClass:NSString.class] ? g[@"share_token"] : @"",
    };
    NSMutableArray *cache = [[[self defaults] arrayForKey:kGalleries] mutableCopy] ?: [NSMutableArray array];
    [cache addObject:entry];
    [[self defaults] setObject:cache forKey:kGalleries];
    return entry;
}

// The destination chosen in a publish action's ContactSheet tab, persisted by us (keyed per action)
// as a fallback in case Capture One does not echo it back via task.settings.
- (NSString *)storedActionGallery:(COPluginAction *)action {
    NSString *v = [[self defaults] stringForKey:[NSString stringWithFormat:@"act.%@.%@", action.identifier, kGalleryId]];
    return [v isKindOfClass:NSString.class] ? v : nil;
}

#pragma mark COPublishingPlugin

- (NSArray<COPluginAction *> * _Nullable)publishingActionsFileCount:(NSUInteger)fileCount
                                                             error:(NSError * __autoreleasing *)error {
    COPluginAction *action = [[COPluginAction alloc] initWithDisplayName:@"Upload to ContactSheet"];
    action.identifier = @"com.nielsfranke.contactsheet.captureone.upload";
    return @[ action ];
}

- (NSArray<COFileHandlingPluginTask *> * _Nullable)tasksForAction:(COPluginAction *)action
                                                        forFiles:(NSArray<NSString *> *)files
                                                           error:(NSError * __autoreleasing *)error {
    return @[ [[COFileHandlingPluginTask alloc] initWithAction:action files:files] ];
}

// Tell Capture One to render full-resolution JPEGs before handing the files over.
- (NSDictionary<COProcessSettingsKey, id<NSSecureCoding>> * _Nullable)processingSettingsForAction:(COPluginAction *)action
                                                                                            error:(NSError * __autoreleasing *)error {
    return @{
        COProcessFileFormatKey: @(COProcessFileFormatJPEG),
        COProcessJpegQualityKey: @(92),
    };
}

// Capture One calls this before rendering/starting the task. Returning NO (with an error) blocks the
// publish — so a missing implementation stalls it entirely. We use it to require configuration.
- (BOOL)validateSettings:(NSDictionary<NSString *, id<NSSecureCoding>> *)settings
               forAction:(COPluginAction *)action
                   error:(NSError * __autoreleasing *)error {
    NSUserDefaults *d = [self defaults];
    if ([self baseURL].length == 0 || [[d stringForKey:kToken] length] == 0) {
        if (error) *error = CSError(@"Configure ContactSheet first: Preferences → Plugins (instance URL + API token).");
        return NO;
    }
    NSString *picked = CSStr(settings[kGalleryId]);
    if (picked.length == 0) picked = [self storedActionGallery:action];
    if (picked.length == 0) picked = [d stringForKey:kGalleryId];
    if (picked.length == 0) {
        if (error) *error = CSError(@"Choose a destination gallery in the ContactSheet tab.");
        return NO;
    }
    return YES;
}

- (COPluginActionPublishResult * _Nullable)startPublishingTask:(COFileHandlingPluginTask *)task
                                                        error:(NSError * __autoreleasing *)error
                                                     progress:(COPluginTaskProgress)progress {
    NSLog(@"[ContactSheet] startPublishingTask: %lu file(s), settings=%@", (unsigned long)task.files.count, task.settings);
    NSString *base = [self baseURL];
    NSString *token = [[self defaults] stringForKey:kToken];
    if (!base.length || !token.length) {
        if (error) *error = CSError(@"Configure the ContactSheet plugin first: Preferences → Plugins → ContactSheet.");
        return nil;
    }

    // Destination: the gallery chosen in this publish action's ContactSheet tab (via task.settings,
    // falling back to our own per-action store), else the default gallery from the Plugin Manager.
    NSString *galleryId = CSStr(task.settings[kGalleryId]);
    if (galleryId.length == 0) galleryId = [self storedActionGallery:task.action];
    if (galleryId.length == 0) galleryId = [[self defaults] stringForKey:kGalleryId];
    if (galleryId.length == 0) { if (error) *error = CSError(@"No destination gallery selected."); return nil; }

    NSArray<NSString *> *files = task.files;
    if (files.count == 0) { if (error) *error = CSError(@"No files to upload."); return nil; }

    NSString *boundary = [@"----ContactSheet" stringByAppendingString:NSUUID.UUID.UUIDString];
    NSMutableData *body = [NSMutableData data];
    NSUInteger included = 0;
    for (NSString *path in files) {
        if (task.cancelled) return [[COPluginActionPublishResult alloc] initWithURL:nil message:nil];
        NSData *fileData = [NSData dataWithContentsOfFile:path];
        if (!fileData) continue;
        NSString *part = [NSString stringWithFormat:
            @"--%@\r\nContent-Disposition: form-data; name=\"files\"; filename=\"%@\"\r\nContent-Type: image/jpeg\r\n\r\n",
            boundary, path.lastPathComponent];
        [body appendData:[part dataUsingEncoding:NSUTF8StringEncoding]];
        [body appendData:fileData];
        [body appendData:[@"\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
        included++;
    }
    [body appendData:[[NSString stringWithFormat:@"--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding]];
    if (included == 0) { if (error) *error = CSError(@"Could not read the rendered files."); return nil; }

    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@/api/galleries/%@/images", base, galleryId]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [req setValue:[@"multipart/form-data; boundary=" stringByAppendingString:boundary] forHTTPHeaderField:@"Content-Type"];

    CSUploader *up = [CSUploader new];
    up.task = task;
    up.progress = progress;
    NSError *upErr = nil;
    NSInteger code = [up uploadRequest:req body:body error:&upErr];
    NSLog(@"[ContactSheet] upload of %lu file(s) → HTTP %ld", (unsigned long)included, (long)code);

    if (code < 0) { if (error) *error = CSError([@"Upload failed: " stringByAppendingString:(upErr.localizedDescription ?: @"network error")]); return nil; }
    if (code == 401) { if (error) *error = CSError(@"Unauthorized — the API token may be invalid or revoked."); return nil; }
    if (code == 403) { if (error) *error = CSError(@"Forbidden — the token lacks the images:write permission."); return nil; }
    if (code == 429) { if (error) *error = CSError(@"Rate limited — too many uploads. Try again shortly."); return nil; }
    if (code < 200 || code >= 300) { if (error) *error = CSError([NSString stringWithFormat:@"Server returned HTTP %ld.", (long)code]); return nil; }

    NSString *msg = [NSString stringWithFormat:@"Uploaded %lu photo%@ to ContactSheet.",
                     (unsigned long)included, included == 1 ? @"" : @"s"];
    return [[COPluginActionPublishResult alloc] initWithURL:[self publicURLForGallery:galleryId base:base] message:msg];
}

#pragma mark COActionSettings (per-publish settings, shown in the Publish dialog)

- (NSArray<COSettingsElementsGroup *> * _Nullable)settingsForAction:(COPluginAction *)action
                                                          settings:(NSDictionary<NSString *, id<NSSecureCoding>> *)settings
                                                             error:(NSError * __autoreleasing *)error {
    NSUserDefaults *d = [self defaults];
    COSettingsElementsGroup *group = [[COSettingsElementsGroup alloc] initWithIdentifier:@"contactsheet-dest" title:@"ContactSheet"];

    COSettingsListItem *galList = [[COSettingsListItem alloc] initWithIdentifier:kGalleryId title:@"Gallery"];
    NSArray *galleries = [d arrayForKey:kGalleries];
    NSMutableArray<COSettingsListOption *> *opts = [NSMutableArray array];
    for (NSDictionary *g in galleries) {
        [opts addObject:[COSettingsListOption settingsListOptionWithValue:g[@"id"] title:g[@"name"]]];
    }
    galList.options = opts;
    NSString *cur = CSStr(settings[kGalleryId]);
    if (cur.length == 0) cur = [self storedActionGallery:action];
    if (cur.length == 0) cur = [d stringForKey:kGalleryId];
    galList.value = cur;
    galList.informativeText = galleries.count ? @"Destination gallery for this export." : @"Load galleries in Preferences → Plugins first.";

    group.elements = @[ galList ];
    return @[ group ];
}

- (BOOL)didUpdateValue:(id<NSSecureCoding>)value forSetting:(NSString *)identifier
               action:(COPluginAction *)action settings:(NSDictionary<NSString *, id<NSSecureCoding>> *)settings
       callbackAction:(COActionSettingsCallbackAction *)callbackAction error:(NSError * __autoreleasing *)error {
    // Mirror the per-publish gallery choice into our own store (keyed per action), so it survives
    // even if Capture One does not echo it back through task.settings.
    NSString *sv = CSStr(value);
    if ([identifier isEqualToString:kGalleryId] && sv) {
        [[self defaults] setObject:sv forKey:[NSString stringWithFormat:@"act.%@.%@", action.identifier, kGalleryId]];
    }
    return YES;
}

#pragma mark COSettings (Plugin Manager UI)

- (NSArray<COSettingsElementsGroup *> * _Nullable)settingsWithError:(NSError * __autoreleasing *)error {
    NSUserDefaults *d = [self defaults];
    COSettingsElementsGroup *group = [[COSettingsElementsGroup alloc] initWithIdentifier:@"contactsheet" title:@"ContactSheet"];
    NSMutableArray<COSettingsElement *> *els = [NSMutableArray array];

    COSettingsTextItem *urlItem = [[COSettingsTextItem alloc] initWithIdentifier:kURL title:@"Instance URL"];
    urlItem.value = [d stringForKey:kURL];
    urlItem.informativeText = @"Your ContactSheet address, e.g. https://photos.example.com";
    [els addObject:urlItem];

    COSettingsTextItem *tokenItem = [[COSettingsTextItem alloc] initWithIdentifier:kToken title:@"API token"];
    tokenItem.value = [d stringForKey:kToken];
    tokenItem.secure = YES;
    tokenItem.informativeText = @"A cs_pat_… token from Settings → API tokens (needs galleries + images:write).";
    [els addObject:tokenItem];

    COSettingsButtonItem *loadBtn = [[COSettingsButtonItem alloc] initWithIdentifier:@"loadGalleries" title:@"Load galleries"];
    [els addObject:loadBtn];

    COSettingsListItem *galList = [[COSettingsListItem alloc] initWithIdentifier:kGalleryId title:@"Default gallery"];
    NSArray *galleries = [d arrayForKey:kGalleries];
    NSMutableArray<COSettingsListOption *> *opts = [NSMutableArray array];
    for (NSDictionary *g in galleries) {
        [opts addObject:[COSettingsListOption settingsListOptionWithValue:g[@"id"] title:g[@"name"]]];
    }
    galList.options = opts;
    galList.value = [d stringForKey:kGalleryId];
    galList.informativeText = galleries.count ? @"Pre-selected destination — you can still pick another per export." : @"Enter the URL + token, then click Load galleries.";
    [els addObject:galList];

    COSettingsTextItem *newGal = [[COSettingsTextItem alloc] initWithIdentifier:kNewGallery title:@"New gallery"];
    newGal.value = [d stringForKey:kNewGallery];
    newGal.informativeText = @"Type a name, then Create gallery — it's added to ContactSheet and the list.";
    [els addObject:newGal];

    COSettingsButtonItem *createBtn = [[COSettingsButtonItem alloc] initWithIdentifier:@"createGallery" title:@"Create gallery"];
    [els addObject:createBtn];

    group.elements = els;
    return @[ group ];
}

- (BOOL)didUpdateValue:(id<NSSecureCoding>)value forSetting:(NSString *)identifier
                 error:(NSError * __autoreleasing *)error callback:(COSettingsCallback)callback {
    [[self defaults] setObject:value forKey:identifier];
    return YES;
}

- (BOOL)handleEvent:(COSettingsEvent)event forSettingsItem:(COSettingsItem *)item
              error:(NSError * __autoreleasing *)error callback:(COSettingsCallback)callback {
    if (event != COSettingsEventButtonClick) return YES;
    NSUserDefaults *d = [self defaults];

    if ([item.identifier isEqualToString:@"loadGalleries"]) {
        NSError *fetchErr = nil;
        NSArray *galleries = [self fetchGalleriesWithError:&fetchErr];
        if (!galleries) { if (error) *error = fetchErr; return NO; }
        [d setObject:galleries forKey:kGalleries];
        if (callback) callback(COSettingsCallbackActionRefresh, nil);
    } else if ([item.identifier isEqualToString:@"createGallery"]) {
        NSString *name = [[d stringForKey:kNewGallery] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (name.length == 0) { if (error) *error = CSError(@"Type a name for the new gallery first."); return NO; }
        NSError *createErr = nil;
        NSDictionary *created = [self createGalleryNamed:name error:&createErr];
        if (!created) { if (error) *error = createErr; return NO; }
        [d setObject:created[@"id"] forKey:kGalleryId];  // select the new gallery as default
        [d removeObjectForKey:kNewGallery];               // clear the input
        if (callback) callback(COSettingsCallbackActionRefresh, nil);
    }
    return YES;
}

@end
