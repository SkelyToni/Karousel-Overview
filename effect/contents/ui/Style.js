.pragma library

// Sizes, timings and colors shared by the overview's components.

// Layout, in logical pixels unless noted.
var zoom = 0.48;              // overview scale of a desktop relative to the screen
var rowGap = 64;              // vertical space between desktop rows
var rowMargin = 36;           // space above and below the row strip
var stripMargin = 32;         // horizontal inset of each row's scrolling strip
var columnSpacing = 12;       // extra gap between columns once fully open
var desktopRadius = 12;
var previewRadius = 7;
var selectionWidth = 4;
var captionHeight = 25;
var captionFontSize = 11;

// Transition.
var chromeStart = 0.4;        // reveal at which borders and captions start to show
var panelExit = 0.7;          // reveal at which panel copies have fully left
var previewSlideMs = 180;     // previews moving after a layout change
var captionFadeMs = 120;
var dragFadeMs = 100;
var refreshIntervalMs = 150;  // layout polling while the overview is open

// Input.
var wheelAngleScale = 1.8;    // angleDelta to pixels for mouse wheels
var gestureGain = 2;          // four-finger swipes reach the end in 1/2 of KWin's travel
var gestureCommit = 0.5;      // released swipes past this share of the way complete
var gestureFlick = 1.5;       // reveal per second that completes or reverts by direction
var edgeScroll = {
    horizontalZone: 64, horizontalSpeed: 0.7,  // px, px per ms at the very edge
    verticalZone: 72, verticalSpeed: 0.6
};

// Backdrop.
var backdropBlur = 64;        // matches Plasma's built-in overview
var backdropDim = 0.45;
var desktopDim = 0.35;        // dimming of each desktop row's wallpaper
var translucentBlur = 40;     // stands in for KWin's blur behind translucent windows

// Colors.
var backdropColor = "#11141c";
var previewBacking = "#181c25";
var accent = "#78a7ff";
var desktopBorder = "#3b4252";
var desktopBorderSelected = "#7287a8";
var captionBackground = "#cc141821";
var captionText = "#eef0f5";
var dragTokenColor = "#26324a";
var dropGhostFill = "#4078a7ff";
var dropGhostBorder = "#a8c7ff";
