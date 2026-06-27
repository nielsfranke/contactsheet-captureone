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
static NSString * const kNewGallery = @"newGalleryName"; // publish-dialog "new gallery" name field
static NSString * const kFilter = @"galleryFilter";     // publish-dialog list filter
static NSString * const kCreate = @"createGalleryNow";  // publish-dialog "Create" checkbox
static NSString * const kMode = @"newGalleryMode";      // mode for a newly created gallery
static NSString * const kPresets = @"presets";          // [{id,name}] — each is its own publish action
static NSString * const kNewPreset = @"newPresetName";  // Plugin-Manager "add recipe" field

static NSError *CSError(NSString *msg) {
    return [NSError errorWithDomain:@"ContactSheet" code:1 userInfo:@{ NSLocalizedDescriptionKey: msg }];
}

// A settings/dict value arrives typed as id<NSSecureCoding> (no -isKindOfClass:); coerce to NSString.
static NSString *CSStr(id value) {
    return [value isKindOfClass:NSString.class] ? (NSString *)value : nil;
}

// Flatten the gallery tree (children) into a display list, indenting nested galleries by depth so
// the hierarchy is visible in the dropdown. Non-breaking spaces survive the list rendering.
static void CSFlatten(NSArray *nodes, NSInteger depth, NSMutableArray *out) {
    for (NSDictionary *g in nodes) {
        if (![g isKindOfClass:NSDictionary.class]) continue;
        NSString *name = CSStr(g[@"name"]) ?: @"(unnamed)";
        NSString *indent = [@"" stringByPaddingToLength:(depth * 4) withString:@" " startingAtIndex:0];
        NSString *display = depth > 0 ? [NSString stringWithFormat:@"%@↳ %@", indent, name] : name;
        NSString *gid = CSStr(g[@"id"]);
        if (gid) {
            [out addObject:@{ @"id": gid, @"name": display, @"share_token": (CSStr(g[@"share_token"]) ?: @""),
                              @"search": name.lowercaseString }];
        }
        if ([g[@"children"] isKindOfClass:NSArray.class]) CSFlatten(g[@"children"], depth + 1, out);
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

- (NSImage *)icon {
    return [[NSBundle bundleForClass:self.class] imageForResource:@"ContactSheet"];
}

// Export recipes — each is a separate publish action (Capture One persists its render recipe per
// action; we remember its gallery per action). Stored as [{id,name}].
- (NSArray<NSDictionary *> *)presets {
    NSArray *p = [[self defaults] arrayForKey:kPresets];
    return [p isKindOfClass:NSArray.class] ? p : @[];
}

- (void)savePresets:(NSArray *)presets {
    [[self defaults] setObject:presets forKey:kPresets];
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
    CSFlatten(json, 0, flat);
    if (flat.count == 0) { if (error) *error = CSError(@"No galleries found for this token."); return nil; }
    return flat;
}

// POST /api/galleries → the new gallery dict {id,name,share_token}, appended to the cache. nil + *error.
- (NSDictionary *)createGalleryNamed:(NSString *)name mode:(NSString *)mode error:(NSError **)error {
    NSString *base = [self baseURL];
    NSString *token = [[self defaults] stringForKey:kToken];
    if (!base.length || !token.length) { if (error) *error = CSError(@"Enter the instance URL and API token first."); return nil; }
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[base stringByAppendingString:@"/api/galleries"]]];
    req.HTTPMethod = @"POST";
    [req setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{ @"name": name, @"mode": (mode.length ? mode : @"presentation") } options:0 error:nil];
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
    NSString *gname = [g[@"name"] isKindOfClass:NSString.class] ? g[@"name"] : name;
    NSDictionary *entry = @{
        @"id": g[@"id"],
        @"name": gname,
        @"share_token": [g[@"share_token"] isKindOfClass:NSString.class] ? g[@"share_token"] : @"",
        @"search": gname.lowercaseString,
    };
    NSMutableArray *cache = [[[self defaults] arrayForKey:kGalleries] mutableCopy] ?: [NSMutableArray array];
    [cache addObject:entry];
    [[self defaults] setObject:cache forKey:kGalleries];
    return entry;
}

// Per-action settings we persist ourselves (keyed by action id): the publish-dialog gallery choice
// (a fallback in case Capture One doesn't echo task.settings) plus the transient filter / new-name.
- (NSString *)actStr:(NSString *)key for:(COPluginAction *)action {
    NSString *v = [[self defaults] stringForKey:[NSString stringWithFormat:@"act.%@.%@", action.identifier, key]];
    return [v isKindOfClass:NSString.class] ? v : nil;
}

- (void)setAct:(NSString *)key for:(COPluginAction *)action to:(NSString *)value {
    NSString *k = [NSString stringWithFormat:@"act.%@.%@", action.identifier, key];
    if (value.length) [[self defaults] setObject:value forKey:k];
    else [[self defaults] removeObjectForKey:k];
}

#pragma mark COPublishingPlugin

- (NSArray<COPluginAction *> * _Nullable)publishingActionsFileCount:(NSUInteger)fileCount
                                                             error:(NSError * __autoreleasing *)error {
    NSImage *icon = [self icon];
    NSArray<NSDictionary *> *presets = [self presets];
    NSMutableArray<COPluginAction *> *actions = [NSMutableArray array];

    if (presets.count == 0) {
        // No recipes defined → a single default action.
        COPluginAction *a = [[COPluginAction alloc] initWithDisplayName:@"Upload to ContactSheet"];
        a.identifier = @"com.nielsfranke.contactsheet.captureone.upload";
        if (icon) a.image = icon;
        [actions addObject:a];
    } else {
        // One action per recipe; Capture One persists each action's render recipe separately.
        for (NSDictionary *p in presets) {
            NSString *pid = CSStr(p[@"id"]);
            if (!pid.length) continue;
            NSString *name = CSStr(p[@"name"]);
            COPluginAction *a = [[COPluginAction alloc] initWithDisplayName:(name.length ? name : @"ContactSheet")];
            a.identifier = [@"com.nielsfranke.contactsheet.captureone.preset." stringByAppendingString:pid];
            if (icon) a.image = icon;
            [actions addObject:a];
        }
    }
    return actions;
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
    if (picked.length == 0) picked = [self actStr:kGalleryId for:action];
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
    if (galleryId.length == 0) galleryId = [self actStr:kGalleryId for:task.action];
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
    NSMutableArray<COSettingsElement *> *els = [NSMutableArray array];
    NSArray *galleries = [d arrayForKey:kGalleries];

    // Filter — only worth showing for large libraries; narrows the gallery list below.
    NSString *filter = nil;
    if (galleries.count > 15) {
        filter = [self actStr:kFilter for:action];
        COSettingsTextItem *filterItem = [[COSettingsTextItem alloc] initWithIdentifier:kFilter title:@"Filter galleries"];
        filterItem.value = filter;
        [els addObject:filterItem];
    }

    // Gallery list, filtered + hierarchy-indented.
    COSettingsListItem *galList = [[COSettingsListItem alloc] initWithIdentifier:kGalleryId title:@"Gallery"];
    NSString *f = filter.lowercaseString;
    NSMutableArray<COSettingsListOption *> *opts = [NSMutableArray array];
    for (NSDictionary *g in galleries) {
        if (f.length && ![(CSStr(g[@"search"]) ?: @"") containsString:f]) continue;
        [opts addObject:[COSettingsListOption settingsListOptionWithValue:g[@"id"] title:g[@"name"]]];
    }
    galList.options = opts;
    NSString *cur = CSStr(settings[kGalleryId]);
    if (cur.length == 0) cur = [self actStr:kGalleryId for:action];
    if (cur.length == 0) cur = [d stringForKey:kGalleryId];
    galList.value = cur;
    galList.informativeText = !galleries.count ? @"Load galleries in Preferences → Plugins first."
        : (opts.count ? @"Destination gallery for this export." : @"No galleries match the filter.");
    [els addObject:galList];

    // Create a new gallery: type a name, then tick "Create new gallery" (explicit confirmation —
    // nothing is created just by typing).
    COSettingsTextItem *newGal = [[COSettingsTextItem alloc] initWithIdentifier:kNewGallery title:@"New gallery"];
    newGal.value = [self actStr:kNewGallery for:action];
    newGal.informativeText = @"Name for a new gallery.";
    [els addObject:newGal];

    COSettingsListItem *modeItem = [[COSettingsListItem alloc] initWithIdentifier:kMode title:@"Mode"];
    modeItem.options = @[
        [COSettingsListOption settingsListOptionWithValue:@"presentation" title:@"Showcase"],
        [COSettingsListOption settingsListOptionWithValue:@"collaboration" title:@"Review"],
    ];
    modeItem.value = [self actStr:kMode for:action] ?: @"presentation";
    [els addObject:modeItem];

    COSettingsBoolItem *createItem = [[COSettingsBoolItem alloc] initWithIdentifier:kCreate title:@"Create new gallery"];
    createItem.value = NO;  // always rendered unticked; ticking it creates the gallery above
    createItem.informativeText = @"Tick to create the gallery named above and select it.";
    [els addObject:createItem];

    group.elements = els;
    return @[ group ];
}

- (BOOL)didUpdateValue:(id<NSSecureCoding>)value forSetting:(NSString *)identifier
               action:(COPluginAction *)action settings:(NSDictionary<NSString *, id<NSSecureCoding>> *)settings
       callbackAction:(COActionSettingsCallbackAction *)callbackAction error:(NSError * __autoreleasing *)error {
    // Mirror the per-publish gallery choice into our own store (keyed per action), so it survives
    // even if Capture One does not echo it back through task.settings.
    if ([identifier isEqualToString:kGalleryId]) {
        if (CSStr(value)) [self setAct:kGalleryId for:action to:CSStr(value)];
    } else if ([identifier isEqualToString:kNewGallery]) {
        [self setAct:kNewGallery for:action to:(CSStr(value) ?: @"")];  // remember the name; do NOT create
    } else if ([identifier isEqualToString:kMode]) {
        [self setAct:kMode for:action to:(CSStr(value) ?: @"presentation")];
    } else if ([identifier isEqualToString:kFilter]) {
        [self setAct:kFilter for:action to:(CSStr(value) ?: @"")];
        if (callbackAction) *callbackAction = COActionSettingsCallbackActionRefresh;  // re-filter the list
    } else if ([identifier isEqualToString:kCreate]) {
        BOOL on = [(id)value isKindOfClass:NSNumber.class] && [(NSNumber *)value boolValue];
        if (on) {  // explicit confirmation → create the gallery named above
            NSString *name = [[self actStr:kNewGallery for:action] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (name.length == 0) { if (error) *error = CSError(@"Type a gallery name first."); return NO; }
            NSString *mode = [self actStr:kMode for:action] ?: @"presentation";
            NSError *createErr = nil;
            NSDictionary *created = [self createGalleryNamed:name mode:mode error:&createErr];
            if (!created) { if (error) *error = createErr; return NO; }
            [self setAct:kGalleryId for:action to:created[@"id"]];  // select the new gallery
            [self setAct:kNewGallery for:action to:@""];            // clear the name field
            if (callbackAction) *callbackAction = COActionSettingsCallbackActionRefresh;
        }
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
    galList.informativeText = galleries.count ? @"Default destination — you can pick another (or create one) per export." : @"Enter the URL + token, then click Load galleries.";
    [els addObject:galList];

    group.elements = els;

    // Recipes tab — manage export recipes. Each recipe is a separate "Upload to ContactSheet …"
    // publish action; Capture One persists its render recipe (Format & Size) per action, and the
    // plugin remembers its gallery per action. Add / rename / remove here.
    COSettingsElementsGroup *recipes = [[COSettingsElementsGroup alloc] initWithIdentifier:@"recipes" title:@"Recipes"];
    NSMutableArray<COSettingsElement *> *rels = [NSMutableArray array];
    for (NSDictionary *p in [self presets]) {
        NSString *pid = CSStr(p[@"id"]);
        if (!pid.length) continue;
        COSettingsTextItem *nameItem = [[COSettingsTextItem alloc] initWithIdentifier:[@"presetName." stringByAppendingString:pid] title:@"Recipe"];
        nameItem.value = CSStr(p[@"name"]);
        [rels addObject:nameItem];
        COSettingsButtonItem *rm = [[COSettingsButtonItem alloc] initWithIdentifier:[@"presetRemove." stringByAppendingString:pid] title:@"Remove"];
        [rels addObject:rm];
    }
    COSettingsTextItem *newPreset = [[COSettingsTextItem alloc] initWithIdentifier:kNewPreset title:@"New recipe"];
    newPreset.value = [d stringForKey:kNewPreset];
    newPreset.informativeText = @"A recipe is a Publish action with its own export settings + gallery.";
    [rels addObject:newPreset];
    COSettingsButtonItem *addPreset = [[COSettingsButtonItem alloc] initWithIdentifier:@"presetAdd" title:@"Add recipe"];
    [rels addObject:addPreset];
    recipes.elements = rels;

    return @[ group, recipes ];
}

- (BOOL)didUpdateValue:(id<NSSecureCoding>)value forSetting:(NSString *)identifier
                 error:(NSError * __autoreleasing *)error callback:(COSettingsCallback)callback {
    if ([identifier hasPrefix:@"presetName."]) {  // rename a recipe
        NSString *pid = [identifier substringFromIndex:@"presetName.".length];
        NSString *name = CSStr(value) ?: @"";
        NSMutableArray *ps = [NSMutableArray array];
        for (NSDictionary *p in [self presets]) {
            [ps addObject:[CSStr(p[@"id"]) isEqualToString:pid] ? @{ @"id": pid, @"name": name } : p];
        }
        [self savePresets:ps];
    } else {
        [[self defaults] setObject:value forKey:identifier];
    }
    return YES;
}

- (BOOL)handleEvent:(COSettingsEvent)event forSettingsItem:(COSettingsItem *)item
              error:(NSError * __autoreleasing *)error callback:(COSettingsCallback)callback {
    if (event != COSettingsEventButtonClick) return YES;

    if ([item.identifier isEqualToString:@"loadGalleries"]) {
        NSError *fetchErr = nil;
        NSArray *galleries = [self fetchGalleriesWithError:&fetchErr];
        if (!galleries) { if (error) *error = fetchErr; return NO; }
        [[self defaults] setObject:galleries forKey:kGalleries];
        if (callback) callback(COSettingsCallbackActionRefresh, nil);
    } else if ([item.identifier isEqualToString:@"presetAdd"]) {
        NSString *name = [[[self defaults] stringForKey:kNewPreset] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (name.length == 0) { if (error) *error = CSError(@"Type a recipe name first."); return NO; }
        NSMutableArray *ps = [[self presets] mutableCopy];
        [ps addObject:@{ @"id": NSUUID.UUID.UUIDString, @"name": name }];
        [self savePresets:ps];
        [[self defaults] removeObjectForKey:kNewPreset];
        if (callback) callback(COSettingsCallbackActionRefresh, nil);
    } else if ([item.identifier hasPrefix:@"presetRemove."]) {
        NSString *pid = [item.identifier substringFromIndex:@"presetRemove.".length];
        NSMutableArray *ps = [NSMutableArray array];
        for (NSDictionary *p in [self presets]) {
            if (![CSStr(p[@"id"]) isEqualToString:pid]) [ps addObject:p];
        }
        [self savePresets:ps];
        if (callback) callback(COSettingsCallbackActionRefresh, nil);
    }
    return YES;
}

@end
