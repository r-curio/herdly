---
name: Steer
description: A black notch instrument for macOS, read in one glance - one sprite, one task name, one count.
platform: macos
colors:
  ground: "#000000"
  ink: "#e6e6e6"
  text: "#8f8f8f"
  dim: "#787878"
  well: "#2a2a2a"
  sprite: "#22c55e"
  sprite-light: "#4cdc80"
  usage-codex: "#3b82f6"
  usage-claude: "#d97757"
  seam: "rgba(255, 255, 255, 0.08)"
typography:
  title:
    fontFamily: "SF Mono, ui-monospace, Menlo, monospace"
    fontSize: "12pt"
    fontWeight: 600
  label:
    fontFamily: "SF Mono, ui-monospace, Menlo, monospace"
    fontSize: "12pt"
    fontWeight: 400
  body:
    fontFamily: "SF Mono, ui-monospace, Menlo, monospace"
    fontSize: "11pt"
    fontWeight: 400
  count:
    fontFamily: "SF Mono, ui-monospace, Menlo, monospace"
    fontSize: "11pt"
    fontWeight: 500
    fontFeature: "tnum"
  caption:
    fontFamily: "SF Mono, ui-monospace, Menlo, monospace"
    fontSize: "10pt"
    fontWeight: 400
rounded:
  badge: "4pt"
  control: "5pt"
  focus: "6pt"
  ear: "8pt"
  corner: "18pt"
spacing:
  hair: "3pt"
  xs: "4pt"
  sm: "6pt"
  md: "8pt"
  row: "10pt"
  seam: "12pt"
  stack: "14pt"
  inset: "16pt"
  name: "18pt"
components:
  strip:
    backgroundColor: "{colors.ground}"
    textColor: "{colors.text}"
    typography: "{typography.label}"
    height: "40pt"
    padding: "0 16pt"
  badge:
    backgroundColor: "{colors.well}"
    textColor: "{colors.ink}"
    typography: "{typography.count}"
    rounded: "{rounded.badge}"
    padding: "0 2pt"
    size: "16pt"
  button-notch:
    backgroundColor: "{colors.well}"
    textColor: "{colors.ink}"
    typography: "{typography.body}"
    rounded: "{rounded.control}"
    padding: "4pt 8pt"
  button-notch-emphasized:
    backgroundColor: "{colors.well}"
    textColor: "{colors.ink}"
    typography: "{typography.title}"
    rounded: "{rounded.control}"
    padding: "4pt 8pt"
  button-notch-pressed:
    backgroundColor: "{colors.ink}"
    textColor: "{colors.ground}"
  button-notch-disabled:
    backgroundColor: "{colors.well}"
    textColor: "{colors.dim}"
  option-notch:
    backgroundColor: "{colors.well}"
    textColor: "{colors.ink}"
    digitColor: "the session's sprite highlight"
    typography: "{typography.body}"
    rounded: "{rounded.control}"
    padding: "4pt 8pt"
  option-notch-chosen:
    backgroundColor: "the session's sprite body"
    textColor: "{colors.ground}"
    fontWeight: 600
  row-title:
    textColor: "{colors.ink}"
    typography: "{typography.title}"
  row-session:
    textColor: "{colors.dim}"
    typography: "{typography.body}"
  detail-label:
    textColor: "{colors.dim}"
    typography: "{typography.body}"
    width: "58pt"
  detail-value:
    textColor: "{colors.text}"
    typography: "{typography.body}"
---

# Design System: Steer

## Overview

**Creative North Star: "The Instrument in the Housing"**

Steer has two designed surfaces. The notch panel, described in most of this document, is the instrument. The Settings window, described in its own section near the end, is a native macOS window where the user tunes that instrument. The notch panel is a single pure-black shape that grows out of the bottom of the macOS menu bar as if it were part of the camera housing. It is read the way a gauge is read. Three readings sit on one line: a green 8-bit sprite that steps while Codex is working, the name of the task in a gray monospaced face, and a dark-gray count of items that need the user. Everything else lives one hover away and is drawn from the same three materials: black ground, gray type in a single monospaced family, and dark wells for anything pressable.

The world is deliberately austere. Color belongs to each session's mark alone: each session has one of six colors, chosen from its identifier so it stays with the session, and its mark is the sprite unless the user picks another indicator style. There is one typeface, and it is the system monospaced face at 10 to 12 points. Depth is not a shadow; the panel has no window shadow at all, because a shadow rim would outline the shape and break its fusion with the menu bar. The only edge inside the panel is a one-point seam at eight percent white between the strip and the open queue. Motion is a reading, not an ornament: the sprite's two-frame step is the working signal, the frame resize is a short ease-out, and Reduce Motion replaces the step with a slow breathe and removes the resize animation entirely.

This is not the glossy dynamic island. It refuses glow, gradient, glass, the pulsing dot, and the spring bounce. It also refuses pictorial chrome: no glyph icons, no logo, no wordmark. The sprite is the one picture in the system.

The instrument is configurable within those materials. In Settings the user chooses:
- what the strip shows: the left wing, a center label on external displays, and the usage bars;
- the session indicator style;
- how wide the open panel is (Standard, Wide, Extra wide);
- how the open queue is sorted and grouped;
- when completions move to "Earlier".

The MacBook notch and external displays each keep their own choices. Every option is drawn from the same black ground, gray ladder, wells, and session colors. An option may change what is shown, but never adds a new material: no glow, no fade-pulse, no gradient. The defaults are the instrument described here: sprites and count, sprite indicator, compact usage, standard panel width, needs-attention order, no grouping, Earlier after 5 minutes.

**Key Characteristics:**
- One black shape fused to the menu bar: flat top, concave 8pt ears, deep 18pt bottom radii, no window shadow
- One monospaced face (SF Mono via the system monospaced design) at 10, 11, and 12pt; semibold only for titles and the emphasized action
- One color: the green sprite body and its lighter highlight; every other value is a gray on black, except the fills of the strip's usage bars, which name their source
- Dark-gray wells (#2a2a2a) for the badge and every control; a pressed control inverts to light ink with black text
- Dense, left-aligned rows separated by whitespace, not lines; the single seam is the only rule drawn
- Motion carries meaning: a 0.5 s sprite step means working, a 0.18 s ease-out resize means the panel changed size

## Colors

An achromatic ladder on pure black with a single green, reserved for the sprite, and two source hues reserved for the fills of the strip's usage bars.

### Primary
- **Sprite Green** (`{colors.sprite}`): the sprite's body cells, and nothing else. It is the only chroma outside the usage bars; it appears in the strip, and again at the head of a "working" row in the open queue.
- **Sprite Highlight** (`{colors.sprite-light}`): the sprite's ear and eye cells. A lighter green that gives the 6x4 bitmap its read at two points per cell.

### Usage
- **Codex Blue** (`{colors.usage-codex}`): the fill of Codex's usage bars (`NotchStyle.codexUsage`), and nothing else.
- **Claude Orange** (`{colors.usage-claude}`): the fill of Claude's usage bars (`NotchStyle.claudeUsage`), and nothing else.

### Neutral
- **Ground** (`{colors.ground}`): the panel itself, pure black so it fuses with the menu bar and the camera housing. Also the text color of a pressed control.
- **Ink** (`{colors.ink}`): row titles, badge digits, control labels, the focus ring, and the fill of a pressed control. The brightest gray; reserved for what must be read first.
- **Text** (`{colors.text}`): the task name in the strip, detail values, and explanatory sentences. The reading gray.
- **Dim** (`{colors.dim}`): session labels, row ages, the identity line's project and branch, detail-table labels, the "Not provided by Codex" placeholder, the keyboard hint, and the label of a disabled control. Holds 4.7:1 on black, so tertiary never drops below legibility.
- **Well** (`{colors.well}`): the badge and every control at rest, and every cell of the unlit sprite. The only surface tone other than black.
- **Seam** (`{colors.seam}`): a one-point line between the strip and the open queue. White at eight percent is the only edge drawn inside the panel.

### Named Rules
**The One Color Rule.** A session's colour belongs to its mark: the sprite, or the dot, bar, or tint the user chose instead (see Session indicator styles). The mark lends it to exactly one other place: the answer options of that session's question, where the digit is drawn in the session's highlight and the option the user chose fills with the session's body colour under black text. The one exception is the usage bars in the strip: each bar's fill carries a fixed source hue, Codex blue (#3b82f6) and Claude orange (#d97757), so the two subscriptions read apart at a glance; their captions and percents stay gray. No badge, title, ring, or other control carries hue; every other state is spoken through motion and gray. A question row is headed by its session's standing sprite so the colour on the options reads as "this session", never as a category.

**The Gray Ladder Rule.** Emphasis moves down four fixed steps: ink for what is read first, text for what is read, dim for what is there if needed, well for what is pressable. Do not add a fifth gray.

## Typography

**Display Font:** none. There is no display face.
**Body Font:** SF Mono (the system monospaced design, `.system(design: .monospaced)`)
**Label/Mono Font:** same family; the whole system is monospaced.

**Character:** One typeface at three sizes. The monospaced face makes the strip read like an instrument readout and lets the detail table align as a grid without rules. Weight, not size, carries hierarchy: 12pt semibold for a row title, 12pt regular for the task name, 11pt for everything the user reads or presses, 10pt for the single keyboard hint.

### Hierarchy
- **Title** (600, 12pt): row titles in the open queue ("Permission needed", "Codex desktop finished", or the session name on a working row), the test-notification heading. Ink.
- **Label** (400, 12pt): the task name in the collapsed strip. Text gray; single line, tail-truncated. The only truncation in the system.
- **Body** (400, 11pt): detail values, explanatory sentences, session labels, control labels, the disclosure title. Text gray for values, dim for labels and session identifiers. Wraps in full.
- **Count** (500, 11pt, tabular digits): the badge number.
- **Caption** (400, 10pt): the keyboard hint at the foot of the full queue. Dim.

### Named Rules
**The One Face Rule.** Every glyph on the panel is the system monospaced face. No second family, no display face, no proportional fallback for prose.

**The Wrap, Never Truncate Rule.** Commands and reasons wrap in full inside the open queue; nothing is cut with an ellipsis. The strip's task name is the sole exception, and it is one line by definition.

**Spotlight detail.** An automatically opened notification is a single-item glance-and-act surface, not the queue. Its title and session label establish what happened and where. An approval request reads top to bottom rather than as a field table: Codex's ask (its reason, or a `description`/`justification` it put in its tool input) as a 12pt regular line in ink; then the action as a dim word leading the command in ink, wrapped in full; then a dim line naming the task (when the session label does not already) and "in" the working directory, with the home folder shortened to `~` and the full path on hover, Copy Path, and VoiceOver; then one status line. A live request says "Decide by" its deadline (time only, dim). A handed-back request says "Handed back with no decision · asked 2m ago" in text gray, from the arrival time, because Steer records no hand-back time. The raw request sits behind "Show full request" only when it holds something the card does not already show. Other cards add the exact turn's working directory as the same dim "in" line. The notification's own prompt or question, current status, and valid actions follow in reading order; a completion ends with its bounded final-response preview. Technical identities, transport routes, and duplicated state or source labels stay out of the interface. The full queue retains its compact treatment.

## Layout

The panel is one column, left-aligned, centered on the display. On a display with a camera housing the collapsed strip is the housing row itself: exactly the housing height, anchored to the top edge of the screen, with one sprite per session (at most three, each in its own color; the unlit sprite while there is none), the "+N" overflow mark, and the count in a 112pt wing left of the housing and the Codex weekly limit readout (a 4pt by 14pt vertical bar, well track filled in Codex blue from the bottom, with the percent in ink beside it; an empty track and a dim dash when unknown) in a 60pt wing right of it (the name is read in the open queue); while Codex also reports a five-hour window, the same readout with a dim "5h" caption sits 8pt ahead of the weekly one and that wing is 112pt, the left wing unmoved; while a Claude root reports current windows, the newest reading's "5h" and "7d" readouts, filled in Claude orange, sit ahead of Codex's, 12pt from the Codex group, and the wing grows 62pt per Claude readout (room for "100%") plus that 4pt group gap (`UsageStripReadouts.wingWidth`); the open queue grows downward from that row. Elsewhere the strip is inline with the menu bar row, as tall as the bar and anchored to the top edge, or, on an external monitor showing no menu bar (a full-screen app), 40pt tall and tucked above the screen edge and slid in only while the pointer touches the top edge, the panel is hovered or focused, or a new item is spotlit. Its frame is the body width plus two 8pt ears. Collapsed, the body is the two wings plus the housing width (never narrower than 200pt); open, it is 60pt wider than collapsed, split evenly between the two wings so the housing stays centered (`NotchPlacement.expandedGrowth`; on a display without a housing the left wing takes it), and never narrower than 380pt; the Wide and Extra wide panel widths grow it by 160pt or 260pt instead, never narrower than 480pt or 580pt, and never past 16pt from either side of the display (`PanelWidth`); it becomes exactly as tall as its content, capped at 480pt with the queue scrolling inside. On a display without a housing the same shape appears as a compact top-center strip.

Content is inset 16pt from each side of the frame (ear plus 8pt). In the strip the first sprite sits 4pt in from the inset, the sprites, overflow mark, and badge follow at 6pt gaps, and the usage readouts are pushed to the right edge of their wing. The open queue begins with the seam, 12pt above the first row. Rows stack at 14pt; inside a row, the title line, any sentence, the detail table, and the control row stack at 8pt; the detail table's own lines sit at 3pt. Detail labels occupy a fixed 58pt column with an 8pt gutter, so values align as a grid. Controls sit in a row at 6pt gaps. A 14pt bottom pad closes the queue.

No breakpoints and no grid beyond this: the panel is a single fixed-width column on every display.

**Display profiles.** Strip and queue options are stored separately for two profiles:
- **MacBook notch:** any display with a camera housing.
- **External display:** any display without one.

The panel uses the profile of the display it is placed on, and switches when it moves to the other kind. Both profiles start with the same defaults.

## Elevation & Depth

Flat, by construction. The window carries no shadow (`hasShadow = false`) because a shadow rim would outline the panel and undo its fusion with the menu bar; the black shape's edge is read only against the wallpaper below. Inside the panel, depth is tonal and minimal: wells (#2a2a2a) rise from the black ground for pressable things, and a single one-point seam at eight percent white separates the strip from the queue. There are no borders, no glass, no blur, no gradient, and no scroll bar: the open queue scrolls with its indicator hidden.

### Named Rules
**The Fused Shape Rule.** The panel has no shadow, no border, and no rim. Its only drawn edge is the seam between strip and queue.

**The Well Rule.** Anything the user can press is a well: #2a2a2a on black, continuous 5pt corners (4pt for the badge). Pressing inverts the well to ink with black text. Nothing else raises off the ground.

## Shapes

The silhouette is the system's signature. The top edge is flat and meets the menu bar; at each top corner a concave quarter-circle ear (8pt, centered outside the body on the menu bar edge) fillets the panel into the housing so it reads as one shape growing out of it; the two bottom corners are deep convex arcs (18pt). When the panel is too short for the full corner, the radius shrinks to fit rather than overlapping.

Inside, every corner is continuous (SwiftUI `.continuous` style) and small: 4pt on the badge, 5pt on controls, 6pt on the focus ring that sits 2pt outside a control. The sprite is the only hard-edged shape: a 6x4 bitmap at 2pt per cell, 12x8pt total, with no anti-aliased corners.

## Components

### Buttons
Text-only wells in the panel's own vocabulary. No icons.
- **Shape:** continuous 5pt corners; 4pt vertical and 8pt horizontal padding.
- **Default (`button-notch`):** well background, ink label, 11pt regular. Used for "Open Session", "Deny", "Dismiss".
- **Emphasized (`button-notch-emphasized`):** same well, label in 11pt semibold. Used once per approval row, on "Approve once".
- **Pressed:** background inverts to ink, label to black. No scale, no spring.
- **Focus:** a 1.5pt ring in ink at 90% opacity, 6pt continuous corners, 2pt outside the control. Visible whenever the control has keyboard focus.
- **Disabled:** label drops to dim and the whole control to 60% opacity.

### Badge
The count of items to check, hidden at zero.
- **Style:** well background, ink digits in 11pt medium tabular figures, continuous 4pt corners, 16pt minimum square with 2pt horizontal padding.
- **State:** none. It counts; it does not blink or change color.

### Sprite
The one picture in the system and the default working signal. The strip always uses sprites when its left wing shows them; the open queue uses the user's chosen indicator style.
- **Form:** a 6-column by 4-row bitmap at 2pt per cell (12x8pt). Body cells in sprite green, ear and eye cells in sprite highlight.
- **Working:** alternates two frames every 0.5 s (the feet step). Under Reduce Motion it holds frame one and breathes in opacity between 50% and 100% on a 2.4 s cycle.
- **Idle:** frame one, still. Hidden from accessibility; the strip's label speaks for it.
- **Unlit:** the mark of an empty notch, shown while no session is listed. Frame one with every cell in well gray, so the eyes close into the body; still, with no step or breathe, and no session's color, so it never reads as a session. It sits where the first sprite would.
- **Placement:** leads the strip; leads a "working" row title in the open queue (offset up 1pt to sit on the baseline).

### Session indicator styles
The mark that leads each row in the open queue. The user picks one style for each display profile. Every style uses the session's colour and follows the sprite's timing: a two-step change every 0.5 s while working, never a fade or pulse.
- **Sprite (default):** described above.
- **Dot:** a 6pt circle centred in the sprite's 12pt slot.
  - Working: steps between body and highlight every 0.5 s.
  - Idle: holds the body colour.
  - Unlit: well gray.
- **Bar:** a 3x12pt rounded bar at the row's leading edge, in the same slot, with the same states as the dot.
- **Tint:** the row header sits on a 5pt continuous well filled with the session's body colour at 18%.
  - Working: the tint steps to 26% and back every 0.5 s.
  - Idle: holds at 18%.
  - Nothing else in the row changes colour.
- **Reduce Motion:** the sprite breathes as it does today. Dot, bar, and tint hold their working value still.
- **Slot:** every style occupies the same 12pt leading slot, or the row header for tint, so titles stay aligned whichever style is chosen.

### Strip
The collapsed reading and the header of the open panel.
- **Layout:** 40pt tall; sprite, then task name 18pt to its right in 12pt regular text gray (one line, tail-truncated), then the badge at the far right.
- **Left wing** (user option):
  - **Sprites and count (default):** as described in Layout.
  - **Count only:** keeps the badge and drops the sprites and the "+N" overflow. While any session is working, one stepping sprite (the first working session's) sits before the badge, so the working signal is never lost.
  - **None:** leaves the wing empty, so the strip is a quiet black shape. Hovering still opens the queue, and a new item still spotlights.
- **Center label** (external displays only): Task name (the top-priority item's task name), Session name, or Off.
  - It is drawn in 12pt regular text gray, one line, tail-truncated, centred between the wings.
  - On a display with a camera housing it is never drawn, because the housing covers the space.
- **Usage bars** (user option): Compact (default), Weekly only, or Hidden. Weekly only drops the "5h" readouts of both sources and keeps Claude's seven-day and Codex's weekly readout, both without a caption since each is weekly; the fill hue tells them apart, and the right wing narrows to match. Hidden removes the readouts and shrinks the right wing to its minimum width.
- **Interaction:** the whole strip is a plain button that expands the queue; keyboard focus draws the ink ring around it (6pt corners, 1.5pt, 6pt outside horizontally).

### Group headings
With grouping on (State, Agent, or Project), the open queue inserts a heading above each group.
- **Text:** the group name ("Needs you", "Done", "Working"; the agent name; or the project folder's last path component).
- **Style:** 10pt caption, dim, 6pt above the group's first row. No rule or line is drawn.
- **Sorting:** groups keep queue priority, so a group holding a live approval comes first. Rows sort inside their group.
- **"Earlier":** stays a heading inside whichever group holds the older completions, followed by the number of Earlier rows in 11pt dim.
- **Folded Earlier row:** one line: a chevron, the title in 11pt text gray, and the session name in dim, with the age lane on the right. The fold is a plain button with the ink focus ring; opening it restores the 12pt ink title and shows the identity line, details, and controls.

### Cards / Containers
Rows are not cards. There is no card surface, border, or shadow; a row is a left-aligned stack on the black ground, separated from its neighbors by 14pt of whitespace.
- **Row header:** title in 12pt semibold ink on the left, the age lane in 11pt dim tabular digits on the right (at least 36pt wide, right-aligned, refreshed every 30 s), aligned on the first baseline with 10pt spacing; a working row leads with the sprite. The spotlight keeps its session label in the age lane's place.
- **Identity line (open queue only):** the session name in 11pt text gray, then "· project @ branch" in 11pt dim, then the source tag pushed right. The name keeps its width first; the place truncates at its tail. The source tag is 10pt text gray on a well with 4pt corners and 5pt by 1pt padding; it carries no hue.
- **Sentence (when present):** 11pt text gray, wrapping in full.
- **Detail table:** label column 58pt wide in dim, values in text gray, 8pt gutter, 3pt line spacing; missing values read "Not provided by Codex" in dim. Command and reason are selectable.
- **Disclosure:** "Show full request" in 11pt text gray reveals the long text inline.
- **Controls:** a row of wells at 6pt gaps beneath the details.
- **Foot (full queue only):** the keyboard hint in 10pt dim, 2pt above the 14pt bottom pad.
- **Empty queue:** with nothing listed, the open queue holds one row in the same grammar (`EmptyQueueReading`). The unlit sprite leads a 12pt semibold ink title. "Nothing running" is followed by a dim line naming the connected sources ("Listening for Codex and Claude."), or by no line while setup is still being checked. "Not connected" appears only once both setups are checked and neither is connected; a text-gray line ("Codex and Claude aren’t reporting to Steer yet.") and an Open Controls well follow it. The strip's spoken label reads the same title.

### Panel motion
- **Resize:** the frame animates to its new size over 0.18 s with an ease-out curve; no spring, no overshoot. Under Reduce Motion, or before first presentation, the frame is set without animation.
- **Hover hold:** the panel treats the pointer as inside for 0.3 s after it leaves, so a slip off the edge does not snap it shut.
- **Spotlight:** a new completion or actionable approval opens only its own row for 3 s; interaction holds it open and the original deadline applies afterward.

## Do's and Don'ts

### Do:
- **Do** draw every surface on pure black (#000000) and let the panel fuse with the menu bar; no window shadow, no rim.
- **Do** use the system monospaced face for every glyph, at 12pt semibold for titles, 12pt regular for the strip name, 11pt for body and controls, 10pt for the single hint.
- **Do** make every pressable thing a #2a2a2a well with continuous 5pt corners (4pt for the badge), and invert it to #e6e6e6 with black text when pressed.
- **Do** keep the ink/text/dim ladder: titles and digits in ink, readings in text, labels and identifiers in dim.
- **Do** show a 1.5pt ink ring at 6pt continuous corners on any control with keyboard focus.
- **Do** wrap commands and reasons in full; align the detail table on a fixed 58pt label column.
- **Do** animate frame changes with a 0.18 s ease-out and honor Reduce Motion by dropping the animation and switching the sprite to its breathe.
- **Do** keep a working signal visible in every configuration: the sprite steps at 0.5 s by default, and dot, bar, and tint step on the same beat. A row is still when idle, and the mark is unlit when no session is listed.

### Don't:
- **Don't** put green anywhere but the sprite; no green badges, rings, titles, or status dots.
- **Don't** add a glow, gradient, glass, blur, border, or shadow to the panel or to any well.
- **Don't** use a spring, bounce, or overshoot on the panel frame, and don't pulse or blink anything.
- **Don't** introduce a second typeface, a display face, or a proportional face for prose.
- **Don't** add glyph icons, a logo, or a wordmark to the panel; controls are text-only wells and the sprite is the only picture.
- **Don't** truncate a command, reason, or detail with an ellipsis inside the open queue; only the strip name is one line.
- **Don't** draw rules or dividers between rows; the one seam under the strip is the only line in the panel.
- **Don't** let a user option introduce a new material: options choose among the existing ground, grays, wells, and session colours; none fades, pulses, glows, or adds a typeface.
- **Don't** bring the notch's black monospaced materials into the Settings window, or native window chrome into the notch.

## Settings Window

The Settings window follows the native macOS conventions measured on macOS 26 (Tahoe). It does not use the notch's materials. Its reference mockup is the "Steer Settings" Paper file.

- **Opening:**
  - From "Settings…" (⌘,) in the app menu, and from "Show Steer controls" in the menu bar item.
  - The window title is the name of the selected pane, and the window reopens on the last pane viewed.
- **Structure:**
  - The window opens at 820x780pt, with a minimum of 720x600.
  - A fixed 210pt sidebar panel, inset 8pt, runs the full window height with 18pt continuous corners. The window buttons sit inside its top edge, and it never collapses.
  - The title bar is an empty unified toolbar 52pt tall, so the buttons line up with each pane's 15pt semibold title row.
  - Grouped sections fill the detail area.
  - Sidebar panes in labeled groups: "Notch" (General, Notch, Notifications), "Connections" (Agents, Terminals), then About on its own. There is no sidebar collapse button.
  - Each sidebar row is 32pt tall with a 20pt colour tile holding a white SF Symbol: gray gear, black sprite, red bell, purple sparkles, dark terminal, blue info.
  - The Notch tile shows the green sprite, the one place the notch's colour appears in the window.
  - The sidebar footer shows the "N working · N to check" status in 11pt secondary text.
- **Forms:**
  - `.formStyle(.grouped)` with system fills. Sections have 12pt continuous corners; rows are 36pt, or 40pt with a segmented control. Separators are inset 10pt.
  - Section headers are 13pt bold. Explanations go in footers, 11pt secondary text.
- **Controls:**
  - Mini switches for booleans, menu pickers for lists, and segmented pickers for two or three short choices.
  - Push buttons for actions. Destructive actions sit alone in the last section, end in an ellipsis, use the destructive role, and confirm first.
- **Colours:**
  - **Dark mode:** a near-black tint closer to the notch. The window and pages are 7.5% white (#131313) and sections are 12.5% white (#202020).
  - **Light mode:** keeps the system values (white window, #F9F9F9 sections).
- **Behaviour:** every change applies immediately. There is no Apply, OK, or Cancel button.
- **Motion:** every click answers within half a second.
  - Pages crossfade and rise 10pt as you switch panes.
  - The preview, indicator tiles, sound list, and disabled rows ease to their new state over 0.4 s.
  - Pressed tiles and rows dip to 97%.
  - Reduce Motion keeps only a 0.15 s crossfade with no movement or scaling.
  - Unlike the notch, the Settings window may use the system's smooth easing.
- **Sound:** switching panes, segments, or indicator tiles plays a soft click (the system "Tink" at 30% volume). It follows the macOS "Play user interface sound effects" setting. The notch never clicks.
- **Notch pane:**
  - A segmented "MacBook notch | External display" picker in the toolbar chooses which profile is being edited.
  - A live preview of the strip on a desktop backdrop sits above the sections and redraws as options change.
  - Options that do not apply to the selected profile, such as Center label on the MacBook notch, are shown disabled with a footer saying why.
- **Indicator picker:** four tiles in a row, Sprite, Dot, Bar, and Tint. Each tile previews two rows on black, one working and one idle. The selected tile has a 2pt accent ring with a 2pt gap.
- **Sound picker:**
  - A list of the macOS system sounds, with a check mark for the selection and a play button to preview it.
  - Glass is marked Default.
  - Choosing a sound plays it once.
