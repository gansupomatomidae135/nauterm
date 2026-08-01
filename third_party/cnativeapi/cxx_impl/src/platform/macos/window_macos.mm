#include <iostream>
#include "../../foundation/id_allocator.h"
#include "../../window.h"
#include "../../window_manager.h"
#include "../../window_registry.h"
#include "coordinate_utils_macos.h"

// Import Cocoa headers
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

static NSString* const NautermFileDropNotification = @"com.korvect.nauterm.file_drop";
static NSString* const NautermFileDropEnabledNotification = @"com.korvect.nauterm.file_drop_enabled";
static const void* kNautermFileDropHandlerKey = &kNautermFileDropHandlerKey;
static BOOL NautermFileDropEnabled = NO;
static id NautermFileDropEnabledObserver = nil;

// Traffic light repositioning — event-driven like Electron
static NSMutableArray* NautermObservers = nil;
static double NautermTrafficX = 8;
static double NautermTrafficY = 32;

// Returns the titleBarContainer (superview.superview of close button) or nil.
static NSView* NautermTitleBarContainer(NSWindow* window) {
  NSButton* closeBtn = [window standardWindowButton:NSWindowCloseButton];
  if (!closeBtn) return nil;
  NSView* buttonContainer = [closeBtn superview];
  if (!buttonContainer) return nil;
  return [buttonContainer superview];
}

static void NautermSetTrafficLightsVisible(NSWindow* window, BOOL visible) {
  NSView* container = NautermTitleBarContainer(window);
  if (container) [container setHidden:!visible];
}

static void NautermInsetTrafficLights(NSWindow* window, double x, double y) {
  if ([window styleMask] & NSWindowStyleMaskFullScreen) return;

  NSButton* closeBtn = [window standardWindowButton:NSWindowCloseButton];
  NSButton* miniBtn = [window standardWindowButton:NSWindowMiniaturizeButton];
  NSButton* zoomBtn = [window standardWindowButton:NSWindowZoomButton];
  if (!closeBtn || !miniBtn || !zoomBtn) return;

  NSView* buttonContainer = [closeBtn superview];
  if (!buttonContainer) return;
  NSView* titleBarContainer = [buttonContainer superview];
  if (!titleBarContainer) return;

  CGFloat buttonHeight = closeBtn.frame.size.height;
  CGFloat titleBarHeight = buttonHeight + y;

  NSRect titleBarRect = titleBarContainer.frame;
  titleBarRect.size.height = titleBarHeight;
  titleBarRect.origin.y = window.frame.size.height - titleBarHeight;
  [titleBarContainer setFrame:titleBarRect];

  CGFloat spaceBetween = miniBtn.frame.origin.x - closeBtn.frame.origin.x;
  CGFloat centeredY = (titleBarHeight - buttonHeight) / 2.0;
  [closeBtn setFrameOrigin:NSMakePoint(x, centeredY)];
  [miniBtn setFrameOrigin:NSMakePoint(x + spaceBetween, centeredY)];
  [zoomBtn setFrameOrigin:NSMakePoint(x + spaceBetween * 2, centeredY)];
}

static void NautermInstallFileDropEnabledObserver() {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    NautermFileDropEnabledObserver =
        [[NSNotificationCenter defaultCenter] addObserverForName:NautermFileDropEnabledNotification
                                                          object:nil
                                                           queue:nil
                                                      usingBlock:^(NSNotification* notification) {
                                                        NSNumber* enabled =
                                                            notification.userInfo[@"enabled"];
                                                        NautermFileDropEnabled = enabled.boolValue;
                                                      }];
  });
}

static NSArray<NSString*>* NautermFilePathsFromPasteboard(NSPasteboard* pasteboard) {
  NSArray<NSURL*>* urls =
      [pasteboard readObjectsForClasses:@[[NSURL class]]
                                options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
  NSMutableArray<NSString*>* paths = [NSMutableArray array];
  for (NSURL* url in urls) {
    if (url.isFileURL && url.path.length > 0) {
      [paths addObject:url.path];
    }
  }
  if (paths.count > 0) {
    return paths;
  }

  NSArray* filenamePaths = [pasteboard propertyListForType:NSFilenamesPboardType];
  if ([filenamePaths isKindOfClass:[NSArray class]]) {
    for (id value in filenamePaths) {
      if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
        [paths addObject:value];
      }
    }
  }
  return paths;
}

static BOOL NautermCanReadFileDrop(NSPasteboard* pasteboard) {
  if (!NautermFileDropEnabled) {
    return NO;
  }
  return NautermFilePathsFromPasteboard(pasteboard).count > 0;
}

static NSDictionary* NautermFileDropLocationUserInfo(id<NSDraggingInfo> sender) {
  NSWindow* window = [sender draggingDestinationWindow];
  NSView* contentView = window.contentView;
  if (!window || !contentView) {
    return @{};
  }
  NSPoint windowPoint = [sender draggingLocation];
  NSPoint contentPoint = [contentView convertPoint:windowPoint fromView:nil];
  CGFloat y = contentView.isFlipped ? contentPoint.y : contentView.bounds.size.height - contentPoint.y;
  return @{@"x" : @(contentPoint.x), @"y" : @(y)};
}

static void NautermPostFileDropTracking(NSString* method, id<NSDraggingInfo> sender, id object) {
  if (!NautermFileDropEnabled) {
    return;
  }
  NSMutableDictionary* userInfo =
      [NSMutableDictionary dictionaryWithDictionary:NautermFileDropLocationUserInfo(sender)];
  userInfo[@"method"] = method;
  [[NSNotificationCenter defaultCenter] postNotificationName:NautermFileDropNotification
                                                      object:object
                                                    userInfo:userInfo];
}

static BOOL NautermPostFileDrop(NSPasteboard* pasteboard, id<NSDraggingInfo> sender, id object) {
  if (!NautermFileDropEnabled) {
    return NO;
  }
  NSArray<NSString*>* paths = NautermFilePathsFromPasteboard(pasteboard);
  if (paths.count == 0) {
    return NO;
  }
  NSMutableDictionary* userInfo =
      [NSMutableDictionary dictionaryWithDictionary:NautermFileDropLocationUserInfo(sender)];
  userInfo[@"method"] = @"filesDropped";
  userInfo[@"paths"] = paths;
  [[NSNotificationCenter defaultCenter] postNotificationName:NautermFileDropNotification
                                                      object:object
                                                    userInfo:userInfo];
  return YES;
}

static void NautermRegisterFileDropForView(NSView* view) {
  if (!view) {
    return;
  }
  NSArray* types = @[NSPasteboardTypeFileURL, NSFilenamesPboardType];
  [view registerForDraggedTypes:types];
  for (NSView* subview in view.subviews) {
    NautermRegisterFileDropForView(subview);
  }
}

@interface NSView (NautermFileDrop)
- (NSDragOperation)nauterm_draggingEntered:(id<NSDraggingInfo>)sender;
- (NSDragOperation)nauterm_draggingUpdated:(id<NSDraggingInfo>)sender;
- (void)nauterm_draggingExited:(id<NSDraggingInfo>)sender;
- (BOOL)nauterm_prepareForDragOperation:(id<NSDraggingInfo>)sender;
- (BOOL)nauterm_performDragOperation:(id<NSDraggingInfo>)sender;
- (void)nauterm_addSubview:(NSView*)view;
- (void)nauterm_addSubview:(NSView*)view
               positioned:(NSWindowOrderingMode)place
               relativeTo:(NSView*)otherView;
@end

@implementation NSView (NautermFileDrop)

+ (void)load {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    NautermInstallFileDropEnabledObserver();

    Class cls = [NSView class];
    Method original;
    Method replacement;

    original = class_getInstanceMethod(cls, @selector(draggingEntered:));
    replacement = class_getInstanceMethod(cls, @selector(nauterm_draggingEntered:));
    method_exchangeImplementations(original, replacement);

    original = class_getInstanceMethod(cls, @selector(draggingUpdated:));
    replacement = class_getInstanceMethod(cls, @selector(nauterm_draggingUpdated:));
    method_exchangeImplementations(original, replacement);

    original = class_getInstanceMethod(cls, @selector(draggingExited:));
    replacement = class_getInstanceMethod(cls, @selector(nauterm_draggingExited:));
    method_exchangeImplementations(original, replacement);

    original = class_getInstanceMethod(cls, @selector(prepareForDragOperation:));
    replacement = class_getInstanceMethod(cls, @selector(nauterm_prepareForDragOperation:));
    method_exchangeImplementations(original, replacement);

    original = class_getInstanceMethod(cls, @selector(performDragOperation:));
    replacement = class_getInstanceMethod(cls, @selector(nauterm_performDragOperation:));
    method_exchangeImplementations(original, replacement);

    original = class_getInstanceMethod(cls, @selector(addSubview:));
    replacement = class_getInstanceMethod(cls, @selector(nauterm_addSubview:));
    method_exchangeImplementations(original, replacement);

    original = class_getInstanceMethod(cls, @selector(addSubview:positioned:relativeTo:));
    replacement = class_getInstanceMethod(cls, @selector(nauterm_addSubview:positioned:relativeTo:));
    method_exchangeImplementations(original, replacement);
  });
}

- (NSDragOperation)nauterm_draggingEntered:(id<NSDraggingInfo>)sender {
  if (NautermCanReadFileDrop([sender draggingPasteboard])) {
    NautermPostFileDropTracking(@"filesDragging", sender, self);
    return NSDragOperationCopy;
  }
  return [self nauterm_draggingEntered:sender];
}

- (NSDragOperation)nauterm_draggingUpdated:(id<NSDraggingInfo>)sender {
  if (NautermCanReadFileDrop([sender draggingPasteboard])) {
    NautermPostFileDropTracking(@"filesDragging", sender, self);
    return NSDragOperationCopy;
  }
  return [self nauterm_draggingUpdated:sender];
}

- (void)nauterm_draggingExited:(id<NSDraggingInfo>)sender {
  NautermPostFileDropTracking(@"filesExited", sender, self);
  [self nauterm_draggingExited:sender];
}

- (BOOL)nauterm_prepareForDragOperation:(id<NSDraggingInfo>)sender {
  if (NautermCanReadFileDrop([sender draggingPasteboard])) {
    return YES;
  }
  return [self nauterm_prepareForDragOperation:sender];
}

- (BOOL)nauterm_performDragOperation:(id<NSDraggingInfo>)sender {
  if (NautermPostFileDrop([sender draggingPasteboard], sender, self)) {
    return YES;
  }
  return [self nauterm_performDragOperation:sender];
}

- (void)nauterm_addSubview:(NSView*)view {
  [self nauterm_addSubview:view];
  NautermRegisterFileDropForView(view);
}

- (void)nauterm_addSubview:(NSView*)view
               positioned:(NSWindowOrderingMode)place
               relativeTo:(NSView*)otherView {
  [self nauterm_addSubview:view positioned:place relativeTo:otherView];
  NautermRegisterFileDropForView(view);
}

@end

@interface NSWindow (NautermFileDrop)
- (void)nauterm_setContentView:(NSView*)contentView;
@end

@implementation NSWindow (NautermFileDrop)

+ (void)load {
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    Class cls = [NSWindow class];
    Method original = class_getInstanceMethod(cls, @selector(setContentView:));
    Method replacement = class_getInstanceMethod(cls, @selector(nauterm_setContentView:));
    method_exchangeImplementations(original, replacement);

  });
}

- (void)nauterm_setContentView:(NSView*)contentView {
  [self nauterm_setContentView:contentView];
  NautermRegisterFileDropForView(contentView);
}

@end

@interface NautermFileDropHandler : NSResponder <NSDraggingDestination>
@end

@implementation NautermFileDropHandler

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
  if ([self canReadFilePathsFromPasteboard:[sender draggingPasteboard]]) {
    NautermPostFileDropTracking(@"filesDragging", sender, self);
    return NSDragOperationCopy;
  }
  return NSDragOperationNone;
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
  if ([self canReadFilePathsFromPasteboard:[sender draggingPasteboard]]) {
    NautermPostFileDropTracking(@"filesDragging", sender, self);
    return NSDragOperationCopy;
  }
  return NSDragOperationNone;
}

- (void)draggingExited:(id<NSDraggingInfo>)sender {
  NautermPostFileDropTracking(@"filesExited", sender, self);
}

- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender {
  return [self canReadFilePathsFromPasteboard:[sender draggingPasteboard]];
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
  return NautermPostFileDrop([sender draggingPasteboard], sender, self);
}

- (BOOL)canReadFilePathsFromPasteboard:(NSPasteboard*)pasteboard {
  return NautermCanReadFileDrop(pasteboard);
}

@end

@interface NativeAPIFileDropWindow : NSWindow
@end

@implementation NativeAPIFileDropWindow

- (instancetype)init {
  self = [super init];
  if (self) {
    [self nautermInstallFileDropHandler];
  }
  return self;
}

- (void)setContentView:(NSView*)contentView {
  [super setContentView:contentView];
  [self nautermInstallFileDropHandler];
}

- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender {
  return [[self nautermFileDropHandler] draggingEntered:sender];
}

- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)sender {
  return [[self nautermFileDropHandler] draggingUpdated:sender];
}

- (void)draggingExited:(id<NSDraggingInfo>)sender {
  [[self nautermFileDropHandler] draggingExited:sender];
}

- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender {
  return [[self nautermFileDropHandler] prepareForDragOperation:sender];
}

- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
  return [[self nautermFileDropHandler] performDragOperation:sender];
}

- (NautermFileDropHandler*)nautermFileDropHandler {
  NautermFileDropHandler* handler = objc_getAssociatedObject(self, kNautermFileDropHandlerKey);
  if (!handler) {
    handler = [[NautermFileDropHandler alloc] init];
    objc_setAssociatedObject(self, kNautermFileDropHandlerKey, handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return handler;
}

- (void)nautermInstallFileDropHandler {
  NautermFileDropHandler* handler = [self nautermFileDropHandler];
  NSArray* types = @[NSPasteboardTypeFileURL, NSFilenamesPboardType];
  [self registerForDraggedTypes:types];
  if (self.contentView) {
    NautermRegisterFileDropForView(self.contentView);
    if (self.contentView.nextResponder != handler) {
      handler.nextResponder = self.contentView.nextResponder;
      self.contentView.nextResponder = handler;
    }
  }
}

@end

// Key for associated objects (used by both window_macos.mm and window_manager_macos.mm)
const void* kWindowIdKey = &kWindowIdKey;

namespace nativeapi {

// Private implementation class
class Window::Impl {
 public:
  Impl(WindowId id, NSWindow* window)
      : id_(id),
        ns_window_(window),
        title_bar_style_(TitleBarStyle::Normal),
        visual_effect_(VisualEffect::None),
        visual_effect_view_(nil) {}
  WindowId id_;
  NSWindow* ns_window_;
  TitleBarStyle title_bar_style_;
  VisualEffect visual_effect_;
  NSVisualEffectView* visual_effect_view_;
};

Window::Window() : Window(nullptr) {}

Window::Window(void* native_window) {
  NSWindow* ns_window = nullptr;
  WindowId id;

  if (native_window == nullptr) {
    // Create new platform object
    id = IdAllocator::Allocate<Window>();
    ns_window = [[NativeAPIFileDropWindow alloc] init];
    ns_window.styleMask = NSWindowStyleMaskResizable | NSWindowStyleMaskTitled |
                          NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable;
    // Store the ID as associated object
    objc_setAssociatedObject(ns_window, kWindowIdKey, [NSNumber numberWithUnsignedLongLong:id],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  } else {
    // Wrap existing platform object - check if it already has an ID
    ns_window = (__bridge NSWindow*)native_window;
    NSNumber* existingId = objc_getAssociatedObject(ns_window, kWindowIdKey);
    if (existingId) {
      // Use existing ID
      id = [existingId unsignedLongLongValue];
    } else {
      // Allocate new ID and store it
      id = IdAllocator::Allocate<Window>();
      objc_setAssociatedObject(ns_window, kWindowIdKey, [NSNumber numberWithUnsignedLongLong:id],
                               OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
  }

  // All initialization logic in one place
  pimpl_ = std::make_unique<Impl>(id, ns_window);
}

Window::~Window() {}

void Window::Focus() {
  if ([pimpl_->ns_window_ respondsToSelector:@selector(nautermInstallFileDropHandler)]) {
    [(id)pimpl_->ns_window_ nautermInstallFileDropHandler];
  }
  [pimpl_->ns_window_ makeKeyAndOrderFront:nil];
}

void Window::Blur() {
  [pimpl_->ns_window_ orderBack:nil];
}

bool Window::IsFocused() const {
  return [pimpl_->ns_window_ isKeyWindow];
}

void Window::Show() {
  if ([pimpl_->ns_window_ respondsToSelector:@selector(nautermInstallFileDropHandler)]) {
    [(id)pimpl_->ns_window_ nautermInstallFileDropHandler];
  }
  [pimpl_->ns_window_ setIsVisible:YES];
  // Panels receive key focus when shown but should not activate the app.
  if (![pimpl_->ns_window_ isKindOfClass:[NSPanel class]]) {
    [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
  }
  [pimpl_->ns_window_ makeKeyAndOrderFront:nil];
}

void Window::ShowInactive() {
  if ([pimpl_->ns_window_ respondsToSelector:@selector(nautermInstallFileDropHandler)]) {
    [(id)pimpl_->ns_window_ nautermInstallFileDropHandler];
  }
  [pimpl_->ns_window_ setIsVisible:YES];
  [pimpl_->ns_window_ orderFrontRegardless];
}

void Window::Hide() {
  [pimpl_->ns_window_ setIsVisible:NO];
  [pimpl_->ns_window_ orderOut:nil];
}

bool Window::IsVisible() const {
  return [pimpl_->ns_window_ isVisible];
}

void Window::Maximize() {
  if (!IsMaximized()) {
    [pimpl_->ns_window_ zoom:nil];
  }
}

void Window::Unmaximize() {
  if (IsMaximized()) {
    [pimpl_->ns_window_ zoom:nil];
  }
}

bool Window::IsMaximized() const {
  return [pimpl_->ns_window_ isZoomed];
}

void Window::Minimize() {
  if (!IsMinimized()) {
    [pimpl_->ns_window_ miniaturize:nil];
  }
}

void Window::Restore() {
  if (IsMinimized()) {
    [pimpl_->ns_window_ deminiaturize:nil];
  }
}

bool Window::IsMinimized() const {
  return [pimpl_->ns_window_ isMiniaturized];
}

void Window::SetFullScreen(bool is_full_screen) {
  if (is_full_screen) {
    if (!IsFullScreen()) {
      [pimpl_->ns_window_ toggleFullScreen:nil];
    }
  } else {
    if (IsFullScreen()) {
      [pimpl_->ns_window_ toggleFullScreen:nil];
    }
  }
}

bool Window::IsFullScreen() const {
  return [pimpl_->ns_window_ styleMask] & NSWindowStyleMaskFullScreen;
}

//// void Window::SetBackgroundColor(Color color);
//// Color Window::GetBackgroundColor() const;

void Window::SetBounds(Rectangle bounds) {
  // Convert from topLeft coordinate system to bottom-left (macOS default)
  NSRect topLeftRect = NSMakeRect(bounds.x, bounds.y, bounds.width, bounds.height);
  NSRect nsRect = NSRectExt::bottomLeft(topLeftRect);
  [pimpl_->ns_window_ setFrame:nsRect display:YES];
}

Rectangle Window::GetBounds() const {
  NSRect frame = [pimpl_->ns_window_ frame];
  // Convert from bottom-left (macOS default) to top-left coordinate system
  CGPoint topLeft = NSRectExt::topLeft(frame);
  Rectangle bounds = {topLeft.x, topLeft.y, static_cast<double>(frame.size.width),
                      static_cast<double>(frame.size.height)};
  return bounds;
}

void Window::SetSize(Size size, bool animate) {
  NSRect frame = [pimpl_->ns_window_ frame];
  frame.origin.y += (frame.size.height - size.height);
  frame.size.width = size.width;
  frame.size.height = size.height;
  if (animate) {
    [[pimpl_->ns_window_ animator] setFrame:frame display:YES animate:YES];
  } else {
    [pimpl_->ns_window_ setFrame:frame display:YES];
  }
}

Size Window::GetSize() const {
  NSRect frame = [pimpl_->ns_window_ frame];
  Size size = {static_cast<double>(frame.size.width), static_cast<double>(frame.size.height)};
  return size;
}

void Window::SetContentSize(Size size) {
  [pimpl_->ns_window_ setContentSize:NSMakeSize(size.width, size.height)];
}

Size Window::GetContentSize() const {
  NSRect frame = [pimpl_->ns_window_ contentRectForFrameRect:[pimpl_->ns_window_ frame]];
  Size size = {static_cast<double>(frame.size.width), static_cast<double>(frame.size.height)};
  return size;
}

void Window::SetContentBounds(Rectangle bounds) {
  // Convert from topLeft coordinate system to bottom-left (macOS default)
  NSRect topLeftRect = NSMakeRect(bounds.x, bounds.y, bounds.width, bounds.height);
  NSRect contentRect = NSRectExt::bottomLeft(topLeftRect);

  // Set the content view frame
  NSRect frameRect = [pimpl_->ns_window_ frameRectForContentRect:contentRect];
  [pimpl_->ns_window_ setFrame:frameRect display:YES];
}

Rectangle Window::GetContentBounds() const {
  NSRect contentRect = [pimpl_->ns_window_ contentRectForFrameRect:[pimpl_->ns_window_ frame]];
  // Convert from bottom-left (macOS default) to top-left coordinate system
  CGPoint topLeft = NSRectExt::topLeft(contentRect);
  Rectangle bounds = {topLeft.x, topLeft.y, static_cast<double>(contentRect.size.width),
                      static_cast<double>(contentRect.size.height)};
  return bounds;
}

void Window::SetMinimumSize(Size size) {
  [pimpl_->ns_window_ setMinSize:NSMakeSize(size.width, size.height)];
}

Size Window::GetMinimumSize() const {
  NSSize size = [pimpl_->ns_window_ minSize];
  return Size{static_cast<double>(size.width), static_cast<double>(size.height)};
}

void Window::SetMaximumSize(Size size) {
  [pimpl_->ns_window_ setMaxSize:NSMakeSize(size.width, size.height)];
}

Size Window::GetMaximumSize() const {
  NSSize size = [pimpl_->ns_window_ maxSize];
  return Size{static_cast<double>(size.width), static_cast<double>(size.height)};
}

void Window::SetResizable(bool is_resizable) {
  NSUInteger style_mask = [pimpl_->ns_window_ styleMask];
  if (is_resizable) {
    style_mask |= NSWindowStyleMaskResizable;
  } else {
    style_mask &= ~NSWindowStyleMaskResizable;
  }
  [pimpl_->ns_window_ setStyleMask:style_mask];
}

bool Window::IsResizable() const {
  return [pimpl_->ns_window_ styleMask] & NSWindowStyleMaskResizable;
}

void Window::SetMovable(bool is_movable) {
  [pimpl_->ns_window_ setMovable:is_movable];
}

bool Window::IsMovable() const {
  return [pimpl_->ns_window_ isMovable];
}

void Window::SetMinimizable(bool is_minimizable) {
  NSUInteger style_mask = [pimpl_->ns_window_ styleMask];
  if (is_minimizable) {
    style_mask |= NSWindowStyleMaskMiniaturizable;
  } else {
    style_mask &= ~NSWindowStyleMaskMiniaturizable;
  }
  [pimpl_->ns_window_ setStyleMask:style_mask];
}

bool Window::IsMinimizable() const {
  return [pimpl_->ns_window_ styleMask] & NSWindowStyleMaskMiniaturizable;
}

void Window::SetMaximizable(bool is_maximizable) {
  NSUInteger style_mask = [pimpl_->ns_window_ styleMask];
  if (is_maximizable) {
    style_mask |= NSWindowStyleMaskResizable;
  } else {
    style_mask &= ~NSWindowStyleMaskResizable;
  }
  [pimpl_->ns_window_ setStyleMask:style_mask];
}

bool Window::IsMaximizable() const {
  return [pimpl_->ns_window_ styleMask] & NSWindowStyleMaskResizable;
}

void Window::SetFullScreenable(bool is_full_screenable) {
  // TODO: Implement this
}

bool Window::IsFullScreenable() const {
  return [pimpl_->ns_window_ styleMask] & NSWindowStyleMaskFullScreen;
}

void Window::SetClosable(bool is_closable) {
  NSUInteger style_mask = [pimpl_->ns_window_ styleMask];
  if (is_closable) {
    style_mask |= NSWindowStyleMaskClosable;
  } else {
    style_mask &= ~NSWindowStyleMaskClosable;
  }
  [pimpl_->ns_window_ setStyleMask:style_mask];
}

bool Window::IsClosable() const {
  return [pimpl_->ns_window_ styleMask] & NSWindowStyleMaskClosable;
}

void Window::SetWindowControlButtonsVisible(bool is_visible) {
  NSButton* closeButton = [pimpl_->ns_window_ standardWindowButton:NSWindowCloseButton];
  NSButton* miniaturizeButton = [pimpl_->ns_window_ standardWindowButton:NSWindowMiniaturizeButton];
  NSButton* zoomButton = [pimpl_->ns_window_ standardWindowButton:NSWindowZoomButton];

  if (closeButton) {
    [closeButton setHidden:!is_visible];
  }
  if (miniaturizeButton) {
    [miniaturizeButton setHidden:!is_visible];
  }
  if (zoomButton) {
    [zoomButton setHidden:!is_visible];
  }
}

bool Window::IsWindowControlButtonsVisible() const {
  NSButton* closeButton = [pimpl_->ns_window_ standardWindowButton:NSWindowCloseButton];
  if (closeButton) {
    return ![closeButton isHidden];
  }
  return true;  // Default to visible if button not found
}

void Window::SetWindowControlButtonsPosition(double x, double y) {
  NSWindow* window = pimpl_->ns_window_;
  NautermTrafficX = x;
  NautermTrafficY = y;

  // Apply immediately
  NautermInsetTrafficLights(window, x, y);

  // Re-apply after a short delay so AppKit's initial layout doesn't override us
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)),
                 dispatch_get_main_queue(), ^{
                   NautermInsetTrafficLights(window, NautermTrafficX, NautermTrafficY);
                 });

  // Remove old observers
  if (NautermObservers) {
    for (id obs in NautermObservers) {
      [NSNotificationCenter.defaultCenter removeObserver:obs];
    }
  }
  NautermObservers = [NSMutableArray new];

  // Helper to add observer
  __weak NSWindow* weakWindow = window;
  void (^addObs)(NSString*) = ^(NSString* name) {
    id obs = [NSNotificationCenter.defaultCenter
        addObserverForName:name
                    object:window
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification* note) {
                  NautermInsetTrafficLights(weakWindow, NautermTrafficX, NautermTrafficY);
                }];
    [NautermObservers addObject:obs];
  };

  // Same events as Electron's RedrawTrafficLights triggers
  addObs(NSWindowDidResizeNotification);
  addObs(NSWindowDidBecomeKeyNotification);
  addObs(NSWindowDidBecomeMainNotification);
  addObs(NSWindowDidResignKeyNotification);
  addObs(NSWindowDidResignMainNotification);
  addObs(NSWindowDidMiniaturizeNotification);
  addObs(NSWindowDidDeminiaturizeNotification);
  addObs(NSWindowDidExposeNotification);

  // Fullscreen exit: hide before animation, reposition + show after
  // (like Electron's NotifyWindowWillLeaveFullScreen / NotifyWindowLeaveFullScreen)
  id willExitObs = [NSNotificationCenter.defaultCenter
      addObserverForName:NSWindowWillExitFullScreenNotification
                  object:window
                   queue:NSOperationQueue.mainQueue
              usingBlock:^(NSNotification* note) {
                NautermSetTrafficLightsVisible(weakWindow, NO);
              }];
  [NautermObservers addObject:willExitObs];

  id didExitObs = [NSNotificationCenter.defaultCenter
      addObserverForName:NSWindowDidExitFullScreenNotification
                  object:window
                   queue:NSOperationQueue.mainQueue
              usingBlock:^(NSNotification* note) {
                NautermInsetTrafficLights(weakWindow, NautermTrafficX, NautermTrafficY);
                NautermSetTrafficLightsVisible(weakWindow, YES);
                [NSNotificationCenter.defaultCenter
                    postNotificationName:@"com.korvect.nauterm.fullscreen_changed"
                                  object:nil
                                userInfo:@{@"fullscreen" : @NO}];
              }];
  [NautermObservers addObject:didExitObs];

  id didEnterObs = [NSNotificationCenter.defaultCenter
      addObserverForName:NSWindowDidEnterFullScreenNotification
                  object:window
                   queue:NSOperationQueue.mainQueue
              usingBlock:^(NSNotification* note) {
                [NSNotificationCenter.defaultCenter
                    postNotificationName:@"com.korvect.nauterm.fullscreen_changed"
                                  object:nil
                                userInfo:@{@"fullscreen" : @YES}];
              }];
  [NautermObservers addObject:didEnterObs];
}

Point Window::GetWindowControlButtonsPosition() const {
  NSButton* closeBtn = [pimpl_->ns_window_ standardWindowButton:NSWindowCloseButton];
  if (closeBtn) {
    return {closeBtn.frame.origin.x, closeBtn.frame.origin.y};
  }
  return {8.0, 8.0};
}

void Window::SetAlwaysOnTop(bool is_always_on_top) {
  [pimpl_->ns_window_ setLevel:is_always_on_top ? NSFloatingWindowLevel : NSNormalWindowLevel];
}

bool Window::IsAlwaysOnTop() const {
  return [pimpl_->ns_window_ level] == NSFloatingWindowLevel;
}

void Window::SetPosition(Point point) {
  // Convert from topLeft coordinate system to bottom-left (macOS default)
  // We need the window height to correctly convert the top-left position
  NSRect frame = [pimpl_->ns_window_ frame];
  CGPoint topLeftPoint = {point.x, point.y};
  NSPoint bottomLeft = NSPointExt::bottomLeftForWindow(topLeftPoint, frame.size.height);
  [pimpl_->ns_window_ setFrameOrigin:bottomLeft];
}

Point Window::GetPosition() const {
  NSRect frame = [pimpl_->ns_window_ frame];
  // Convert from bottom-left (macOS default) to top-left coordinate system
  CGPoint topLeft = NSRectExt::topLeft(frame);
  Point point = {topLeft.x, topLeft.y};
  return point;
}

void Window::Center() {
  // Use NSWindow's center method which automatically centers on the main screen
  [pimpl_->ns_window_ center];
}

void Window::SetTitle(std::string title) {
  [pimpl_->ns_window_ setTitle:[NSString stringWithUTF8String:title.c_str()]];
}

std::string Window::GetTitle() const {
  NSString* title = [pimpl_->ns_window_ title];
  return title ? std::string([title UTF8String]) : std::string();
}

void Window::SetTitleBarStyle(TitleBarStyle style) {
  if ([pimpl_->ns_window_ respondsToSelector:@selector(nautermInstallFileDropHandler)]) {
    [(id)pimpl_->ns_window_ nautermInstallFileDropHandler];
  }
  pimpl_->title_bar_style_ = style;

  if (style == TitleBarStyle::Hidden) {
    // Hide title bar - make it transparent and full size content view
    pimpl_->ns_window_.titleVisibility = NSWindowTitleHidden;
    pimpl_->ns_window_.titlebarAppearsTransparent = YES;
    pimpl_->ns_window_.styleMask |= NSWindowStyleMaskFullSizeContentView;
  } else {
    // Show title bar - restore normal appearance
    pimpl_->ns_window_.titleVisibility = NSWindowTitleVisible;
    pimpl_->ns_window_.titlebarAppearsTransparent = NO;
    pimpl_->ns_window_.styleMask &= ~NSWindowStyleMaskFullSizeContentView;
  }

  // Ensure window remains opaque and has shadow
  pimpl_->ns_window_.opaque = NO;
  pimpl_->ns_window_.hasShadow = YES;

  // Show window buttons
  NSView* titleBarView =
      [[pimpl_->ns_window_ standardWindowButton:NSWindowCloseButton] superview].superview;
  if (titleBarView) {
    titleBarView.hidden = NO;
  }

  [pimpl_->ns_window_ standardWindowButton:NSWindowCloseButton].hidden = NO;
  [pimpl_->ns_window_ standardWindowButton:NSWindowMiniaturizeButton].hidden = NO;
  [pimpl_->ns_window_ standardWindowButton:NSWindowZoomButton].hidden = NO;
}

TitleBarStyle Window::GetTitleBarStyle() const {
  return pimpl_->title_bar_style_;
}

void Window::SetHasShadow(bool has_shadow) {
  [pimpl_->ns_window_ setHasShadow:has_shadow];
  [pimpl_->ns_window_ invalidateShadow];
}

bool Window::HasShadow() const {
  return [pimpl_->ns_window_ hasShadow];
}

void Window::SetOpacity(float opacity) {
  [pimpl_->ns_window_ setAlphaValue:opacity];
}

float Window::GetOpacity() const {
  return [pimpl_->ns_window_ alphaValue];
}

void Window::SetVisualEffect(VisualEffect effect) {
  if (pimpl_->visual_effect_ == effect)
    return;

  pimpl_->visual_effect_ = effect;
  NSWindow* window = pimpl_->ns_window_;

  if (effect == VisualEffect::None) {
    if (pimpl_->visual_effect_view_) {
      [pimpl_->visual_effect_view_ removeFromSuperview];
      pimpl_->visual_effect_view_ = nil;
    }
    [window setOpaque:YES];
    [window setBackgroundColor:[NSColor windowBackgroundColor]];
    return;
  }

  if (!pimpl_->visual_effect_view_) {
    NSView* contentView = [window contentView];
    pimpl_->visual_effect_view_ = [[NSVisualEffectView alloc] initWithFrame:[contentView bounds]];
    [pimpl_->visual_effect_view_ setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [pimpl_->visual_effect_view_ setBlendingMode:NSVisualEffectBlendingModeBehindWindow];
    [contentView addSubview:pimpl_->visual_effect_view_ positioned:NSWindowBelow relativeTo:nil];
  }

  [window setOpaque:NO];
  [window setBackgroundColor:[NSColor clearColor]];

  switch (effect) {
    case VisualEffect::Blur:
      [pimpl_->visual_effect_view_ setMaterial:NSVisualEffectMaterialSidebar];
      break;
    case VisualEffect::Acrylic:
      [pimpl_->visual_effect_view_ setMaterial:NSVisualEffectMaterialUnderWindowBackground];
      break;
    case VisualEffect::Mica:
      [pimpl_->visual_effect_view_ setMaterial:NSVisualEffectMaterialWindowBackground];
      break;
    default:
      break;
  }

  [pimpl_->visual_effect_view_ setState:NSVisualEffectStateActive];
}

VisualEffect Window::GetVisualEffect() const {
  return pimpl_->visual_effect_;
}

void Window::SetBackgroundColor(const Color& color) {
  NSColor* nsColor = [NSColor colorWithRed:color.r / 255.0
                                     green:color.g / 255.0
                                      blue:color.b / 255.0
                                     alpha:color.a / 255.0];
  [pimpl_->ns_window_ setBackgroundColor:nsColor];
}

Color Window::GetBackgroundColor() const {
  NSColor* nsColor = [pimpl_->ns_window_ backgroundColor];

  // Convert NSColor to RGB color space if needed
  NSColor* rgbColor = [nsColor colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
  if (!rgbColor) {
    // Fallback if conversion fails
    return Color::White;
  }

  CGFloat r, g, b, a;
  [rgbColor getRed:&r green:&g blue:&b alpha:&a];

  return Color::FromRGBA(
    static_cast<unsigned char>(r * 255),
    static_cast<unsigned char>(g * 255),
    static_cast<unsigned char>(b * 255),
    static_cast<unsigned char>(a * 255)
  );
}

void Window::SetVisibleOnAllWorkspaces(bool is_visible_on_all_workspaces) {
  [pimpl_->ns_window_ setCollectionBehavior:is_visible_on_all_workspaces
                                                ? NSWindowCollectionBehaviorCanJoinAllSpaces
                                                : NSWindowCollectionBehaviorDefault];
}

bool Window::IsVisibleOnAllWorkspaces() const {
  return [pimpl_->ns_window_ collectionBehavior] & NSWindowCollectionBehaviorCanJoinAllSpaces;
}

void Window::SetIgnoreMouseEvents(bool is_ignore_mouse_events) {
  [pimpl_->ns_window_ setIgnoresMouseEvents:is_ignore_mouse_events];
}

bool Window::IsIgnoreMouseEvents() const {
  return [pimpl_->ns_window_ ignoresMouseEvents];
}

void Window::SetFocusable(bool is_focusable) {
  // TODO: Implement this
}

bool Window::IsFocusable() const {
  return [pimpl_->ns_window_ canBecomeKeyWindow];
}

void Window::StartDragging() {
  NSWindow* window = pimpl_->ns_window_;
  if (window.currentEvent) {
    [window performWindowDragWithEvent:window.currentEvent];
  }
}

void Window::StartResizing() {}

WindowId Window::GetId() const {
  return pimpl_->id_;
}

void* Window::GetNativeObjectInternal() const {
  return (__bridge void*)pimpl_->ns_window_;
}

}  // namespace nativeapi
