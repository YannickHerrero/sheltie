# Native design specification

The ignored `do-not-commit/Web-Prototype.zip` export remains the visual source of truth. `herdr-ipad-control.html` takes precedence over handoff notes and earlier images. The app translates that structure into SwiftUI/UIKit; it does not embed the HTML.

## Tokens

| Name | sRGB | Use |
| --- | --- | --- |
| Background | `#E1E2E7` | Workspace and terminal canvas |
| Surface | `#D8D9E0` | App bar, tabs, composers, keybar |
| Foreground | `#1F2F66` | Primary text and controls |
| Muted | `#68709A` | Metadata |
| Border | `#B6BBD1` | Pane and region boundaries |
| Accent | `#2E7DE9` | Focus and selected tabs |
| Success | `#587539` | Connected and done |
| Warning | `#8C6C3E` | Working |
| Danger | `#F52A65` | Blocked and destructive actions |

Display text uses Iowan Old Style with the system serif fallback. Interface text uses the system sans-serif. Operational data and terminal-adjacent labels use the system monospaced face; terminal output uses SwiftTerm’s monospaced UIKit font.

Spacing follows 8, 12, 20, and 32-point steps. Common radii are 8 points and modal cards use 14 points. Interactive targets are at least 44 points even where the visible glyph is smaller.

## Regions

The connected wide layout is composed in this order:

1. 58-point app bar: brand, paired Mac/connection selector, optional provider meter.
2. 205–240-point sidebar: Spaces in the upper 42%, grouped Agents below.
3. 46-point horizontally scrolling Herdr tab strip.
4. Recursive Herdr pane layout, including 38-point native pane headers.
5. Per-pane 54-point agent or shell composer.
6. 50-point horizontally scrolling special-key row.

Boundaries are low-contrast one-point rules. The selected pane receives a restrained accent outline. There is no workspace hero, global search, global New Session button, or right-side inspector in the approved screen.

## Adaptive behavior

The adaptive breakpoint is based directly on the app window’s available width. The prototype’s outer presentation frame is a mockup device, not part of the native application.

- Wide: persistent sidebar and complete recursive pane split.
- Compact: app-bar menu button, drawer sidebar, one pane at a time, explicit pane switcher.
- Narrow (560 points or less): condensed connection and usage metadata and no keybar note.
- Wide and compact layouts both fill the window edge to edge without an outer margin, rounded container, or drop shadow.
- Internal surfaces retain their own borders and hierarchy; only the enclosing presentation card is removed.

Window width—not orientation or device model—controls adaptation so Split View and Stage Manager behave consistently.

## Interaction mapping

- Space selection focuses its active Herdr tab and pane.
- Agent selection focuses its linked space, tab, and pane.
- Tab selection focuses the Herdr tab.
- Pane focus determines hardware-keyboard, composer, and keybar routing.
- Divider drags update local geometry continuously and send one split-ratio action on release.
- Context menus expose rename, move, split, zoom, and destructive close operations.
- Destructive operations require a confirmation dialog.
- The agent composer sends semantic agent text plus submit.
- The shell composer sends text and Enter atomically.
- SwiftTerm sends direct hardware/software keyboard bytes to the focused pane.
- Sticky keybar modifiers clear after one key.

## Operational states

The app preserves the connected geometry when practical and presents explicit native treatment for:

- no paired instances;
- pairing in progress or rejected;
- connecting and reconnecting;
- disconnected or incompatible bridge;
- empty workspaces, tabs, or panes;
- loading terminal frames;
- closed/error terminal streams;
- missing optional provider usage;
- action errors and session expiry.

## Accessibility

- Every status color has a spoken state label.
- Selected workspaces and tabs expose selection traits.
- Pane dividers expose adjustable accessibility actions.
- Controls use semantic labels instead of relying on symbols alone.
- Horizontal regions remain scrollable at larger text sizes.
- Motion respects Reduce Motion.
- Color is never the only indicator for connection, agent state, errors, or selection.

## Visual verification

Use `--demo` for deterministic screenshots. Verify iPhone portrait/compact plus iPad portrait and landscape layouts, then test raw window widths around 820 and 560 points. Screenshots prove geometry only; keyboard repeat, marked text, gestures, menus, dictation, background suspension, and biometric behavior require device testing.
