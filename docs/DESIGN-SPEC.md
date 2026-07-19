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
2. 205–240-point sidebar: Spaces above grouped Agents, defaulting to a 42/58 split with a draggable separator.
3. 46-point horizontally scrolling Herdr tab strip.
4. Recursive Herdr pane layout, including 38-point native pane headers.
5. Per-pane 54-point agent or shell composer.
6. 50-point horizontally scrolling special-key row.

Boundaries are low-contrast one-point rules. The selected pane receives a restrained accent outline. There is no workspace hero, global search, global New Session button, or right-side inspector in the approved screen.

## Adaptive behavior

The phone idiom selects a navigation-first presentation; iPad adaptation is then based directly on available window width. The prototype’s outer presentation frame is a mockup device, not part of the native application.

- iPhone root: the complete Spaces/Agents hierarchy fills the screen.
- iPhone workspace: selecting a space or agent opens one terminal page full-screen with a back control, tabs, pane switcher, composer, and keybar.
- iPad wide: persistent sidebar and complete recursive pane split.
- iPad compact: app-bar menu button, drawer sidebar, one pane at a time, explicit pane switcher.
- Narrow (560 points or less): condensed connection and usage metadata and no keybar note.
- Every presentation fills the window edge to edge without an outer margin, rounded container, or drop shadow.
- Internal surfaces retain their own borders and hierarchy; only the enclosing presentation card is removed.

Window width—not orientation—controls iPad Split View and Stage Manager adaptation.

## Interaction mapping

- The Spaces add control immediately creates and focuses a Herdr workspace rooted at the Mac user's home directory; Herdr supplies its default label.
- Space rows show the shortest unique project-path suffix; matching final components gain only the parent components needed for disambiguation.
- A Space context menu opens its project-root `todo.md` in a native Markdown edit/preview sheet with explicit conflict recovery.
- Space selection focuses its active Herdr tab and pane, then opens the full-screen workspace on iPhone.
- Agent selection focuses its linked space, tab, and pane, then opens the full-screen workspace on iPhone.
- The iPhone workspace back control returns to the full-screen Spaces/Agents hierarchy without changing Herdr focus.
- Tab selection focuses the Herdr tab.
- Pane focus determines hardware-keyboard, composer, and keybar routing.
- Terminal divider drags update local geometry continuously and send one split-ratio action on release.
- The Spaces/Agents separator updates only a persisted local preference, clamps both sections to useful minimum heights, and resets to 42/58 on double-tap.
- Context menus expose rename, move, split, zoom, and destructive close operations.
- Destructive operations require a confirmation dialog.
- The agent composer sends semantic agent text plus submit.
- The shell composer sends text and Enter atomically.
- SwiftTerm sends direct hardware/software keyboard bytes to the focused pane.
- A vertical terminal swipe or the pane menu opens a stable, read-only snapshot of recent Herdr scrollback; live output continues underneath and a Latest control returns to it.
- Terminal history is bounded, memory-only, and exposes native touch, pointer, selection, and VoiceOver scrolling.
- Sticky keybar modifiers clear after one key.
- Settings exposes independent done and blocked notification opt-ins, system permission/denied treatment, Mac provider readiness, and Codex usage health.

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
- Pane dividers and the Spaces/Agents separator expose adjustable accessibility actions.
- Live terminal and terminal-history surfaces have distinct spoken labels; the Latest control reports whether the history view is away from the tail.
- Controls use semantic labels instead of relying on symbols alone.
- Horizontal regions remain scrollable at larger text sizes.
- Motion respects Reduce Motion.
- Color is never the only indicator for connection, agent state, errors, or selection.

## Visual verification

Use `--demo` for deterministic screenshots. Verify iPhone portrait/compact plus iPad portrait and landscape layouts, then test raw window widths around 820 and 560 points. Screenshots prove geometry only; keyboard repeat, marked text, gestures, menus, dictation, background suspension, and biometric behavior require device testing.
