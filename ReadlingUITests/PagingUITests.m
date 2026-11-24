#import <XCTest/XCTest.h>

// XCUIAutomation's event synthesis, the layer under XCUIElement's gestures. Those wait for the app to go idle before
// each gesture, so they never overlap a turn still animating; a reader swiping fast does, and that is what broke curl.
// It's private, so without it the tests are skipped rather than failed.
@interface NSObject (PagingSynthesizedEvents)
- (instancetype)initForTouchAtPoint:(CGPoint)point offset:(double)offset;
- (void)moveToPoint:(CGPoint)point atOffset:(double)offset;
- (void)liftUpAtOffset:(double)offset;
- (instancetype)initWithName:(NSString *)name interfaceOrientation:(UIInterfaceOrientation)orientation;
- (void)addPointerEventPath:(id)path;
- (BOOL)synthesizeWithError:(NSError **)error;
@end

/// A page as its text view names it ("page 2/3 4/12"): one-based chapter and page, and what each runs to.
typedef struct {
    NSInteger chapter, chapters, page, pages;
} ShownPage;

static NSString *Describe(ShownPage page) {
    return [NSString stringWithFormat:@"chapter %ld/%ld page %ld/%ld", page.chapter, page.chapters, page.page, page.pages];
}

static BOOL SamePage(ShownPage a, ShownPage b) { return a.chapter == b.chapter && a.page == b.page; }

static BOOL Follows(ShownPage next, ShownPage page) {
    return page.page < page.pages ? next.chapter == page.chapter && next.page == page.page + 1
                                   : next.chapter == page.chapter + 1 && next.page == 1;
}

/// Paging through bursts of fast, overlapping swipes and taps, each followed by ordinary turns that must land one
/// page at a time. Curl once left a page stranded on top of the pager after overlapping swipes, so every later turn
/// happened out of sight.
@interface PagingUITests : XCTestCase
@end

@implementation PagingUITests {
    XCUIApplication *_app;
    CGSize _size;
}

- (void)setUp {
    self.continueAfterFailure = NO;
}

- (void)testCurl { [self burstsWithTurn:@"curl"]; }
- (void)testSlide { [self burstsWithTurn:@"slide"]; }
- (void)testCover { [self burstsWithTurn:@"cover"]; } // No-animation turns share cover's code.

- (void)burstsWithTurn:(NSString *)turn {
    XCTSkipUnless(NSClassFromString(@"XCPointerEventPath") && NSClassFromString(@"XCSynthesizedEventRecord"),
                  @"XCUIAutomation no longer offers the event synthesis these tests rely on.");
    [self openSecondChapterWithTurn:turn];
    [self checkOrdinaryTurns];
    [self burst:@"forward swipes" count:6 every:0.25 stroke:^(double t, NSInteger i) { return [self forwardAt:t]; }];
    [self burst:@"back swipes into the chapter before" count:10 every:0.25
         stroke:^(double t, NSInteger i) { return [self backAt:t]; }];
    [self burst:@"alternating swipes" count:8 every:0.2
         stroke:^(double t, NSInteger i) { return i % 2 ? [self backAt:t] : [self forwardAt:t]; }];
    [self burst:@"swipes and taps" count:8 every:0.15
         stroke:^(double t, NSInteger i) { return i % 2 ? [self tapAt:t x:0.97] : [self forwardAt:t]; }];
    [self burst:@"very fast swipes" count:12 every:0.13 stroke:^(double t, NSInteger i) { return [self forwardAt:t]; }];
    [self burst:@"back swipes and taps" count:8 every:0.15
         stroke:^(double t, NSInteger i) { return i % 2 ? [self tapAt:t x:0.03] : [self backAt:t]; }];
}

// MARK: Steps

- (void)openSecondChapterWithTurn:(NSString *)turn {
    _app = [[XCUIApplication alloc] init];
    // Large type gives the sample book's chapters enough pages to turn through.
    _app.launchArguments = @[@"-freshLibrary", @"-readerPageTurn", turn, @"-readerFont", @"30", @"-readerTipSeen", @"YES"];
    [_app launch];
    _size = _app.windows.firstMatch.frame.size;
    // A new library holds just the sample book.
    [self tap:[_app.buttons matchingPredicate:[NSPredicate predicateWithFormat:@"identifier BEGINSWITH 'book-'"]].firstMatch];
    // A book opens with the toolbars put away; a tap on the text brings them up once the page is in.
    for (int i = 0; i < 5 && !_app.buttons[@"reader-menu"].exists; i++) {
        [[_app.windows.firstMatch coordinateWithNormalizedOffset:CGVectorMake(0.5, 0.5)] tap];
        [_app.buttons[@"reader-menu"] waitForExistenceWithTimeout:1];
    }
    [self tap:_app.buttons[@"reader-menu"]];
    [self tap:_app.buttons[@"open-chapters"]];
    [self tap:[_app.collectionViews.cells elementBoundByIndex:1]];
    [[_app.windows.firstMatch coordinateWithNormalizedOffset:CGVectorMake(0.5, 0.5)] tap]; // Puts the toolbars away.
    ShownPage start = [self waitForPage:^BOOL(ShownPage page) { return page.chapter == 2 && page.page == 1; }
                                  after:@"opening chapter 2" from:(ShownPage){0, 0, 0, 0}];
    XCTAssertGreaterThan(start.pages, 1);
}

/// Plays one burst of strokes as a reader would, without waiting for any turn to finish, then lets it settle.
- (void)burst:(NSString *)name count:(NSInteger)count every:(double)interval stroke:(id (^)(double, NSInteger))stroke {
    [XCTContext runActivityNamed:name block:^(id<XCTActivity> activity) {
        NSMutableArray *paths = [NSMutableArray array];
        for (NSInteger i = 0; i < count; i++) [paths addObject:stroke(i * interval, i)];
        [self play:paths named:name];
        [NSThread sleepForTimeInterval:1.5];
        [self checkOrdinaryTurns];
    }];
}

/// One swipe forward and one tap back, each left to finish (the other way round on the book's last page). A page
/// stuck on screen, or a turn landing anywhere but the neighbouring page, fails here.
- (void)checkOrdinaryTurns {
    ShownPage start = [self waitForPage:^BOOL(ShownPage page) { return YES; } after:@"the burst" from:(ShownPage){0, 0, 0, 0}];
    BOOL lastPage = start.chapter == start.chapters && start.page == start.pages;
    if (lastPage) {
        [self play:@[[self tapAt:0 x:0.03]] named:@"tap back"];
        ShownPage before = [self waitForPage:^BOOL(ShownPage page) { return Follows(start, page); } after:@"a tap back" from:start];
        [self play:@[[self forwardAt:0]] named:@"swipe forward"];
        [self waitForPage:^BOOL(ShownPage page) { return SamePage(page, start); } after:@"a swipe forward" from:before];
    } else {
        [self play:@[[self forwardAt:0]] named:@"swipe forward"];
        ShownPage next = [self waitForPage:^BOOL(ShownPage page) { return Follows(page, start); } after:@"a swipe forward" from:start];
        [self play:@[[self tapAt:0 x:0.03]] named:@"tap back"];
        [self waitForPage:^BOOL(ShownPage page) { return SamePage(page, start); } after:@"a tap back" from:next];
    }
}

// MARK: Reading the screen

/// The one page on screen. Pages beside it (slide keeps its neighbours just off screen) don't count; two on screen
/// at rest means one is stranded over the other. Read from a single snapshot, as pages come and go mid-turn.
- (BOOL)shownPage:(ShownPage *)shown candidates:(NSArray<NSString *> **)candidates {
    id<XCUIElementSnapshot> root = [_app snapshotWithError:nil];
    NSMutableArray<NSString *> *visible = [NSMutableArray array];
    CGRect screen = {CGPointZero, _size};
    NSMutableArray<id<XCUIElementSnapshot>> *pending = root ? [NSMutableArray arrayWithObject:root] : [NSMutableArray array];
    while (pending.count) {
        id<XCUIElementSnapshot> element = pending.lastObject;
        [pending removeLastObject];
        CGPoint center = CGPointMake(CGRectGetMidX(element.frame), CGRectGetMidY(element.frame));
        if ([element.identifier hasPrefix:@"page "] && CGRectContainsPoint(screen, center)) [visible addObject:element.identifier];
        [pending addObjectsFromArray:element.children];
    }
    if (candidates) *candidates = visible;
    if (visible.count != 1) return NO;
    NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"^page (\\d+)/(\\d+) (\\d+)/(\\d+)$" options:0 error:nil];
    NSTextCheckingResult *match = [pattern firstMatchInString:visible[0] options:0 range:NSMakeRange(0, visible[0].length)];
    if (!match) return NO;
    NSInteger (^number)(NSUInteger) = ^NSInteger(NSUInteger group) {
        return [visible[0] substringWithRange:[match rangeAtIndex:group]].integerValue;
    };
    *shown = (ShownPage){number(1), number(2), number(3), number(4)};
    return YES;
}

- (ShownPage)waitForPage:(BOOL (^)(ShownPage))expected after:(NSString *)action from:(ShownPage)start {
    ShownPage shown = {0, 0, 0, 0};
    NSArray<NSString *> *candidates = @[];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:4];
    while (deadline.timeIntervalSinceNow > 0) {
        if ([self shownPage:&shown candidates:&candidates] && expected(shown)) return shown;
        [NSThread sleepForTimeInterval:0.2];
    }
    NSString *from = start.chapter ? [@" from " stringByAppendingString:Describe(start)] : @"";
    XCTFail(@"After %@%@, the screen shows %@", action, from, candidates.count == 1 ? Describe(shown) : candidates);
    return shown;
}

// MARK: Touches

- (void)tap:(XCUIElement *)element {
    XCTAssertTrue([element waitForExistenceWithTimeout:5], @"%@", element);
    [element tap];
}

- (CGPoint)at:(CGFloat)x y:(CGFloat)y { return CGPointMake(_size.width * x, _size.height * y); }

- (id)strokeFrom:(CGPoint)from to:(CGPoint)to at:(double)start duration:(double)duration {
    id path = [[NSClassFromString(@"XCPointerEventPath") alloc] initForTouchAtPoint:from offset:start];
    for (int step = 1; step <= 6; step++) {
        CGFloat f = step / 6.0;
        [path moveToPoint:CGPointMake(from.x + (to.x - from.x) * f, from.y + (to.y - from.y) * f) atOffset:start + duration * f];
    }
    [path liftUpAtOffset:start + duration + 0.01];
    return path;
}

- (id)forwardAt:(double)t { return [self strokeFrom:[self at:0.8 y:0.5] to:[self at:0.15 y:0.52] at:t duration:0.1]; }
- (id)backAt:(double)t { return [self strokeFrom:[self at:0.2 y:0.5] to:[self at:0.85 y:0.52] at:t duration:0.1]; }

/// A tap in the side margin, clear of any word, so it can only turn.
- (id)tapAt:(double)t x:(CGFloat)x { return [self strokeFrom:[self at:x y:0.5] to:[self at:x y:0.5] at:t duration:0.04]; }

- (void)play:(NSArray *)paths named:(NSString *)name {
    id record = [[NSClassFromString(@"XCSynthesizedEventRecord") alloc] initWithName:name
                                                               interfaceOrientation:UIInterfaceOrientationPortrait];
    for (id path in paths) [record addPointerEventPath:path];
    NSError *error = nil;
    XCTAssertTrue([record synthesizeWithError:&error], @"%@", error);
}

@end
