//
//  NCAutocompleteTextView.m
//  Example
//
//  Created by Daniel Weber on 9/28/14.
//  Copyright (c) 2014 Null Creature. All rights reserved.
//

#import "NCRAutocompleteTextView.h"

#define MAX_RESULTS 10

#define HIGHLIGHT_COLOR [NSColor colorWithCalibratedRed:0.474 green:0.588 blue:0.743 alpha:1]
#define HIGHLIGHT_RADIUS 4.0
#define INTERCELL_SPACING NSMakeSize(0, 5.0)

#define POPOVER_WIDTH 250.0
#define POPOVER_PADDING 3.0

#define POPOVER_APPEARANCE NSPopoverAppearanceHUD
//#define POPOVER_APPEARANCE NSPopoverAppearanceMinimal

#define POPOVER_FONT [NSFont fontWithName:@"Menlo" size:12.0]
// The font for the characters that have already been typed
#define POPOVER_BOLDFONT [NSFont fontWithName:@"Menlo-Bold" size:13.0]
#define POPOVER_TEXTCOLOR [NSColor whiteColor]

// The amount the image is pushed right
#define IMAGE_ORIGIN_X_OFFSET 5
// The amount the image is pushed down
#define IMAGE_ORIGIN_Y_OFFSET -2
// The padding between the image and text
#define IMAGE_PADDING 3

#pragma mark -

@interface ImageAndTextCell : NSTextFieldCell
@property(readwrite, strong) NSImage *image;
@end

@implementation ImageAndTextCell

- (id)init
{
    self = [super init];
    if (self) {
        [self setFont:[NSFont systemFontOfSize:[NSFont smallSystemFontSize]]];
    }
    return self;
}

- (id)copyWithZone:(NSZone *)zone
{
    ImageAndTextCell *cell = (ImageAndTextCell *)[super copyWithZone:zone];
    cell.image = self.image;
    return cell;
}

- (void)drawWithFrame:(NSRect)cellFrame inView:(NSView *)controlView
{
    NSRect newCellFrame = cellFrame;

    if (self.image != nil) {
        NSSize imageSize = [self.image size];
        NSRect imageFrame;
        NSDivideRect(newCellFrame, &imageFrame, &newCellFrame, imageSize.width + IMAGE_ORIGIN_X_OFFSET + IMAGE_PADDING, NSMinXEdge);
        if ([self drawsBackground]) {
            [[self backgroundColor] set];
            NSRectFill(imageFrame);
        }
        imageFrame.origin.x += IMAGE_ORIGIN_X_OFFSET;
        imageFrame.origin.y += IMAGE_ORIGIN_Y_OFFSET;
        imageFrame.size = imageSize;

        [self.image drawInRect:imageFrame
                      fromRect:NSZeroRect
                     operation:NSCompositeSourceOver
                      fraction:1.0
                respectFlipped:YES
                         hints:nil];
    }

    [super drawWithFrame:newCellFrame inView:controlView];
}

- (void)drawInteriorWithFrame:(NSRect)cellFrame inView:(NSView *)controlView
{
    [super drawInteriorWithFrame:cellFrame inView:controlView];
    NSAttributedString *attrString = self.attributedStringValue;
    [attrString drawWithRect:[self titleRectForBounds:cellFrame]
                     options:NSStringDrawingTruncatesLastVisibleLine | NSStringDrawingUsesLineFragmentOrigin];
}

@end

#pragma mark -

@interface NCRAutocompleteTableView : NSTableView

@end

@implementation NCRAutocompleteTableView

- (void)highlightSelectionInClipRect:(NSRect)theClipRect
{
    NSRange visibleRowIndexes = [self rowsInRect:theClipRect];
    NSIndexSet *selectedRowIndexes = [self selectedRowIndexes];
    NSUInteger endRow = visibleRowIndexes.location + visibleRowIndexes.length;
    for (NSInteger row = visibleRowIndexes.location; row < endRow; row++) {
        if ([selectedRowIndexes containsIndex:row]) {
            NSRect rowRect = NSInsetRect([self rectOfRow:row], 0, 0);
            NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:rowRect xRadius:HIGHLIGHT_RADIUS yRadius:HIGHLIGHT_RADIUS];
            [HIGHLIGHT_COLOR set];
            [path fill];
        }
    }
}

@end

#pragma mark -

@interface NCRAutocompleteTextView ()
@property(nonatomic, strong) NSPopover *autocompletePopover;
@property(nonatomic, weak) NCRAutocompleteTableView *autocompleteTableView;
@property(nonatomic, strong) NSMutableArray *matches;
// Used to highlight typed characters and insert text
@property(nonatomic, copy) NSString *substring;
// Used to keep track of when the insert cursor has moved so we
// can close the popover. See didChangeSelection:
@property(nonatomic, assign) NSInteger lastPos;
@end

@implementation NCRAutocompleteTextView

- (void)awakeFromNib
{
    // Make a table view with 1 column and enclosing scroll view. It doesn't
    // matter what the frames are here because they are set when the popover
    // is displayed
    NSTableColumn *column1 = [[NSTableColumn alloc] initWithIdentifier:@"text"];
    [column1 setEditable:NO];
    [column1 setWidth:POPOVER_WIDTH - 2 * POPOVER_PADDING];
    [column1 setDataCell:[[ImageAndTextCell alloc] init]];

    NCRAutocompleteTableView *tableView = [[NCRAutocompleteTableView alloc] initWithFrame:NSZeroRect];
    [tableView setSelectionHighlightStyle:NSTableViewSelectionHighlightStyleSourceList];
    [tableView setBackgroundColor:[NSColor clearColor]];
    [tableView setRowSizeStyle:NSTableViewRowSizeStyleSmall];
    [tableView setIntercellSpacing:INTERCELL_SPACING];
    [tableView setHeaderView:nil];
    [tableView setRefusesFirstResponder:YES];
    [tableView setTarget:self];
    [tableView setDoubleAction:@selector(insert:)];
    [tableView addTableColumn:column1];
    [tableView setDelegate:self];
    [tableView setDataSource:self];
    self.autocompleteTableView = tableView;

    NSScrollView *tableScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    [tableScrollView setDrawsBackground:NO];
    [tableScrollView setDocumentView:tableView];
    [tableScrollView setHasVerticalScroller:YES];

    NSView *contentView = [[NSView alloc] initWithFrame:NSZeroRect];
    [contentView addSubview:tableScrollView];

    NSViewController *contentViewController = [[NSViewController alloc] init];
    [contentViewController setView:contentView];

    self.autocompletePopover = [[NSPopover alloc] init];
    self.autocompletePopover.appearance = POPOVER_APPEARANCE;
    self.autocompletePopover.animates = NO;
    self.autocompletePopover.delegate = self;
    self.autocompletePopover.contentViewController = contentViewController;

    self.matches = [NSMutableArray array];
    self.lastPos = -1;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didChangeSelection:) name:@"NSTextViewDidChangeSelectionNotification" object:nil];
}

- (void)keyDown:(NSEvent *)theEvent
{
    if (self.autocompletePopover.isShown) {
        NSInteger row = self.autocompleteTableView.selectedRow;
        if (theEvent.keyCode == 125) {
            // Down
            [self.autocompleteTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:row + 1] byExtendingSelection:NO];
            [self.autocompleteTableView scrollRowToVisible:self.autocompleteTableView.selectedRow];
            return;
        } else if (theEvent.keyCode == 126) {
            // Up
            [self.autocompleteTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:row - 1] byExtendingSelection:NO];
            [self.autocompleteTableView scrollRowToVisible:self.autocompleteTableView.selectedRow];
            return;
        } else if (theEvent.keyCode == 51) {
            // Delete
            [self.autocompletePopover close];
            [super keyDown:theEvent];
            return;
        } else if (theEvent.keyCode == 36 || theEvent.keyCode == 48) {
            // Return or tab
            [self insert:self];
            return;
        } else if (theEvent.keyCode == 49) {
            // Space
            [self.autocompletePopover close];
            [super keyDown:theEvent];
            return;
        }
    }
    [super keyDown:theEvent];
    [self complete:self];
}

- (void)insert:(id)sender
{
    if (self.autocompleteTableView.selectedRow >= 0 && self.autocompleteTableView.selectedRow < self.matches.count) {
        NSString *string = [self.matches objectAtIndex:self.autocompleteTableView.selectedRow];
        NSInteger beginningOfWord = self.selectedRange.location - self.substring.length;
        [self replaceCharactersInRange:NSMakeRange(beginningOfWord, self.substring.length) withString:string];
    }
    [self.autocompletePopover close];
}

- (void)didChangeSelection:(NSNotification *)notification
{
    if (labs(self.selectedRange.location - self.lastPos) > 1) {
        // If selection moves by more than just one character, hide autocomplete
        [self.autocompletePopover close];
    }
}

- (void)complete:(id)sender
{
    NSInteger startOfWord = self.selectedRange.location;
    for (NSInteger i = startOfWord - 1; i >= 0; i--) {
        if ([self.string characterAtIndex:i] == ' ') {
            break;
        } else {
            startOfWord--;
        }
    }

    NSInteger lengthOfWord = 0;
    for (NSInteger i = startOfWord; i < self.string.length; i++) {
        if ([self.string characterAtIndex:i] == ' ') {
            break;
        } else {
            lengthOfWord++;
        }
    }

    self.substring = [self.string substringWithRange:NSMakeRange(startOfWord, lengthOfWord)];
    NSRange substringRange = NSMakeRange(startOfWord, self.selectedRange.location - startOfWord);

    if (substringRange.length == 0) {
        // This happens when we just started a new word--0 characters
        return;
    }

    // Find the matches from the wordlist
    [self.matches removeAllObjects];
    for (NSString *string in self.wordlist) {
        if ([string rangeOfString:self.substring options:NSAnchoredSearch | NSCaseInsensitiveSearch range:NSMakeRange(0, [string length])].location != NSNotFound) {
            [self.matches addObject:string];
        }
    }

    if (self.matches.count > 0) {
        self.lastPos = self.selectedRange.location;
        [self.matches sortUsingSelector:@selector(compare:)];
        [self.autocompleteTableView reloadData];

        // Make the frame for the popover. We want it to shrink with a small number
        // of items to autocomplete but never grow above a certain limit when there
        // are a lot of items. The limit is set by MAX_RESULTS.
        NSInteger numberOfRows = MIN(self.autocompleteTableView.numberOfRows, MAX_RESULTS);
        CGFloat height = (self.autocompleteTableView.rowHeight + self.autocompleteTableView.intercellSpacing.height) * numberOfRows + 2 * POPOVER_PADDING;
        NSRect frame = NSMakeRect(0, 0, POPOVER_WIDTH, height);
        [self.autocompleteTableView.enclosingScrollView setFrame:NSInsetRect(frame, POPOVER_PADDING, POPOVER_PADDING)];
        [self.autocompletePopover setContentSize:NSMakeSize(NSWidth(frame), NSHeight(frame))];

        [self.autocompleteTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        [self.autocompleteTableView scrollRowToVisible:0];

        // We want to find the middle of the first character to show the popover.
        // firstRectForCharacterRange: will give us the rect at the begeinning of
        // the word, and then we need to find the half-width of the first character
        // to add to it.
        NSRect rect = [self firstRectForCharacterRange:substringRange];
        rect = [self.window convertRectFromScreen:rect];
        rect = [self convertRect:rect fromView:nil];
        NSString *firstChar = [self.substring substringToIndex:1];
        NSSize firstCharSize = [firstChar sizeWithAttributes:@{NSFontAttributeName : self.font}];
        rect.size.width = firstCharSize.width;

        [self.autocompletePopover showRelativeToRect:rect ofView:self preferredEdge:NSMaxYEdge];
    } else {
        [self.autocompletePopover close];
    }
}

- (void)popoverDidShow:(NSNotification *)notification
{
    [self.window makeFirstResponder:self];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
    return self.matches.count;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    return self.matches[row];
}

- (void)tableView:(NSTableView *)tableView willDisplayCell:(id)cell forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row
{
    ImageAndTextCell *imageAndTextCell = (ImageAndTextCell *)cell;

    [imageAndTextCell setDrawsBackground:NO];
    [imageAndTextCell setImage:nil];

    NSMutableAttributedString *as = [[NSMutableAttributedString alloc] initWithString:imageAndTextCell.stringValue attributes:@{NSFontAttributeName : POPOVER_FONT, NSForegroundColorAttributeName : POPOVER_TEXTCOLOR}];
    [imageAndTextCell setAttributedStringValue:as];

    if (self.substring) {
        NSRange range = [imageAndTextCell.stringValue rangeOfString:self.substring options:NSAnchoredSearch | NSCaseInsensitiveSearch];
        [as addAttribute:NSFontAttributeName value:POPOVER_BOLDFONT range:range];
        [imageAndTextCell setAttributedStringValue:as];
    }

    if ([[self delegate] respondsToSelector:@selector(imageForWord:)]) {
        NSImage *image = [[self delegate] imageForWord:self.matches[row]];
        if (image) {
            [imageAndTextCell setImage:image];
        }
    }
}

@end
