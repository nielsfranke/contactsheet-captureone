// SPDX-FileCopyrightText: 2026 Niels Franke
// SPDX-License-Identifier: MIT
//
// ContactSheet — Capture One publish plugin (principal class).
//
// Implements COPublishingPlugin: Capture One renders the selected variants to temp files per the
// export recipe (see -processingSettingsForAction:, added in the upload milestone) and hands their
// paths to -startPublishingTask:…, which uploads them to a ContactSheet gallery.
//
// This is the load-test stage: it registers the publish action and proves the plugin loads in
// Capture One. The real upload (PAT auth + multipart POST to /api/galleries/{id}/images) and the
// settings UI (instance URL / token / gallery picker) are the next milestones.

#import <Cocoa/Cocoa.h>
#import <CaptureOnePlugins/CaptureOnePlugins.h>

@interface CSContactSheetPlugin : COPluginBase <COPublishingPlugin>
@end

@implementation CSContactSheetPlugin

// The actions (export destinations) Capture One offers for the current selection.
- (NSArray<COPluginAction *> * _Nullable)publishingActionsFileCount:(NSUInteger)fileCount
                                                             error:(NSError * __autoreleasing *)error {
    NSLog(@"[ContactSheet] publishingActionsFileCount: %lu", (unsigned long)fileCount);
    COPluginAction *action = [[COPluginAction alloc] initWithDisplayName:@"Upload to ContactSheet"];
    action.identifier = @"com.nielsfranke.contactsheet.captureone.upload";
    return @[ action ];
}

// Map the action onto the unit(s) of work. One task carries the whole batch (one upload request).
- (NSArray<COFileHandlingPluginTask *> * _Nullable)tasksForAction:(COPluginAction *)action
                                                        forFiles:(NSArray<NSString *> *)files
                                                           error:(NSError * __autoreleasing *)error {
    return @[ [[COFileHandlingPluginTask alloc] initWithAction:action files:files] ];
}

// Run the task: upload the rendered files. (Upload logic lands in the next milestone.)
- (COPluginActionPublishResult * _Nullable)startPublishingTask:(COFileHandlingPluginTask *)task
                                                        error:(NSError * __autoreleasing *)error
                                                     progress:(COPluginTaskProgress)progress {
    NSLog(@"[ContactSheet] startPublishingTask files=%@", task.files);
    return [[COPluginActionPublishResult alloc] initWithURL:nil
                                                    message:@"ContactSheet plugin is wired up (upload coming next)."];
}

@end
