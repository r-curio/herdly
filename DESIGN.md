---
name: Herdly
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
  failure: "#3a1d1d"
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
  badge-named:
    backgroundColor: "{colors.well}"
    textColor: "{colors.ink}"
    typography: "{typography.count}"
    rounded: "{rounded.badge}"
    padding: "0 4pt"
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
  seconds-left:
    backgroundColor: "{colors.well}"
    textColor: "{colors.ink}"
    typography: "10pt 600"
    rounded: "{rounded.badge}"
    padding: "1pt 6pt"
  failed-word:
    backgroundColor: "{colors.failure}"
    textColor: "{colors.ink}"
    typography: "{typography.caption}"
    rounded: "{rounded.badge}"
    padding: "1pt 6pt"
  more-rows:
    backgroundColor: "{colors.well}"
    textColor: "{colors.text}"
    typography: "{typography.caption}"
    rounded: "{rounded.badge}"
    padding: "1pt 6pt"
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

# Design System: Herdly

## Overview

**Creative North Star: "The Instrument in the Housing"**

Herdly has two designed surfaces. The notch panel, described in most of this document, is the instrument. The Settings window, described in its own section near the end, is a native macOS window where the user tunes that instrument. The notch panel is a single pure-black shape that grows out of the bottom of the macOS menu bar as if it were part of the camera housing. It is read the way a gauge is read. Three readings sit on one line: a green 8-bit sprite, the animal the user chose, that steps while Codex is working, the name of the task in a gray monospaced face, and a dark-gray count of items that need the user. Everything else lives one hover away and is drawn from the same three materials: black ground, gray type in a single monospaced family, and dark wells for anything pressable.

The world is deliberately austere. Color belongs to each session's mark alone: each session has one of six colors, chosen from its identifier so it stays with the session, and its mark is the sprite: one animal, chosen by the user, drawn for every session. There is one typeface, and it is the system monospaced face at 10 to 12 points. Depth is not a shadow; the panel has no window shadow at all, because a shadow rim would outline the shape and break its fusion with the menu bar. The only edge inside the panel is a one-point seam at eight percent white between the strip and the open queue. Motion is a reading, not an ornament: the sprite's two-frame step is the working signal, the frame resize is a short ease-out, and Reduce Motion replaces the step with a slow breathe and removes the resize animation entirely.

This is not the glossy dynamic island. It refuses glow, gradient, glass, the pulsing dot, and the spring bounce. It also refuses pictorial chrome: no glyph icons, no logo, no wordmark. The sprite is the one picture in the system.

The instrument is configurable within those materials. In Settings the user chooses:
- what the strip shows: the left wing, a center label on external displays, and the usage bars;
- the sprite drawn for every session (Sheep, Critter, Sheepdog, Cow, or Blob);
- how wide the open panel is (Standard, Wide, Extra wide);
- how the open queue is sorted and grouped;
- when completions move to "Earlier".

The MacBook notch and external displays each keep their own choices. Every option is drawn from the same black ground, gray ladder, wells, and session colors. An option may change what is shown, but never adds a new material: no glow, no fade-pulse, no gradient. The defaults are the instrument described here: sprites and count, the Sheep sprite, compact usage, standard panel width, "By need" order, no grouping, "repo @ branch" after each name, Earlier after 5 minutes.

**Key Characteristics:**
- One black shape fused to the menu bar: flat top, concave 8pt ears, deep 18pt bottom radii, no window shadow
- One monospaced face (SF Mono via the system monospaced design) at 10, 11, and 12pt; semibold only for titles and the emphasized action
- One color: the green sprite body and its lighter highlight; every other value is a gray on black, except the fills of the strip's usage bars, which name their source, and the dark red well behind "Failed"
- Dark-gray wells (#2a2a2a) for the badge and every control; a pressed control inverts to light ink with black text
- Dense, left-aligned rows separated by whitespace, not lines; the single seam is the only rule drawn
- Motion carries meaning: a 0.5 s sprite step means working, a 0.18 s ease-out resize means the panel changed size

## Colors

An achromatic ladder on pure black with a single green, reserved for the sprite, and two source hues reserved for the fills of the strip's usage bars.

### Primary
- **Sprite Green** (`{colors.sprite}`): the sprite's body cells, and nothing else. It is the only chroma outside the usage bars; it appears in the strip, and again at the head of each row in the open queue.
- **Sprite Highlight** (`{colors.sprite-light}`): the sprite's highlight cells (ears, eyes, faces, and markings). A lighter green that gives each small bitmap its read at two points per cell.

### Usage
- **Codex Blue** (`{colors.usage-codex}`): the fill of Codex's usage bars (`NotchStyle.codexUsage`), and nothing else.
- **Claude Orange** (`{colors.usage-claude}`): the fill of Claude's usage bars (`NotchStyle.claudeUsage`), and nothing else.

### Failure
- **Failure Well** (`{colors.failure}`): the well behind a queue row's "Failed" (`NotchStyle.failure`), and nothing else. Red marks only failures (D14, agreed 2026-10-21, #314); Handed back, Waiting, and Status unknown stay on the gray ladder.

### Neutral
- **Ground** (`{colors.ground}`): the panel itself, pure black so it fuses with the menu bar and the camera housing. Also the text color of a pressed control.
- **Ink** (`{colors.ink}`): row titles, badge digits, control labels, the focus ring, and the fill of a pressed control. The brightest gray; reserved for what must be read first.
- **Text** (`{colors.text}`): the task name in the strip, detail values, and explanatory sentences. The reading gray.
- **Dim** (`{colors.dim}`): session labels, row ages, the row header's place, a row's plain exception word, queue section names, detail-table labels, the "Not provided by Codex" placeholder, the keyboard hint, and the label of a disabled control. Holds 4.7:1 on black, so tertiary never drops below legibility.
- **Well** (`{colors.well}`): the badge and every control at rest, a live approval's "Ns left", a section's "+N more", and every cell of the unlit sprite. The only surface tone other than black.
- **Seam** (`{colors.seam}`): a one-point line between the strip and the open queue. White at eight percent is the only edge drawn inside the panel.

### Named Rules
**The One Color Rule.** A session's colour belongs to its mark, the sprite. The mark lends it to exactly one other place: the answer options of that session's question, where the digit is drawn in the session's highlight and the option the user chose fills with the session's body colour under black text. The exceptions are the "Failed" well (see Failure) and the usage bars in the strip: each bar's fill carries a fixed source hue, Codex blue (#3b82f6) and Claude orange (#d97757), so the two subscriptions read apart at a glance; their captions and percents stay gray. No badge, title, ring, or other control carries hue; every other state is spoken through motion and gray. A question row is headed by its session's standing sprite so the colour on the options reads as "this session", never as a category.

**The Gray Ladder Rule.** Emphasis moves down four fixed steps: ink for what is read first, text for what is read, dim for what is there if needed, well for what is pressable. Do not add a fifth gray.

## Typography

**Display Font:** none. There is no display face.
**Body Font:** SF Mono (the system monospaced design, `.system(design: .monospaced)`)
**Label/Mono Font:** same family; the whole system is monospaced.

**Character:** One typeface at three sizes. The monospaced face makes the strip read like an instrument readout and lets the detail table align as a grid without rules. Weight, not size, carries hierarchy: 12pt semibold for a row title, 12pt regular for the task name, 11pt for everything the user reads or presses, 10pt for the single keyboard hint.

### Hierarchy
- **Title** (600, 12pt): row titles in the open queue (the session's name on every row), the test-notification heading. Ink.
- **Label** (400, 12pt): the task name in the collapsed strip. Text gray; single line, tail-truncated. The only truncation in the system.
- **Body** (400, 11pt): detail values, explanatory sentences, session labels, control labels, the disclosure title. Text gray for values, dim for labels and session identifiers. Wraps in full.
- **Count** (500, 11pt, tabular digits): the badge number.
- **Caption** (400, 10pt): the keyboard hint at the foot of the full queue, group and section headings, a row's exception word, and "+N more". Dim, except that a section's count is 600 in text gray, "Ns left" is 600 in ink, "Failed" is ink on its red well, and "+N more" is text gray.

### Named Rules
**The One Face Rule.** Every glyph on the panel is the system monospaced face. No second family, no display face, no proportional fallback for prose.

**The Wrap, Never Truncate Rule.** Commands and reasons wrap in full inside the open queue; nothing is cut with an ellipsis. The strip's task name is the sole exception, and it is one line by definition.

**Spotlight detail.** An automatically opened notification is a single-item glance-and-act surface, not the queue. Its title and session label establish what happened and where. An approval request reads top to bottom rather than as a field table: Codex's ask (its reason, or a `description`/`justification` it put in its tool input) as a 12pt regular line in ink; then the action as a dim word leading the command in ink, wrapped in full; then a dim line naming the task (when the session label does not already) and "in" the working directory, with the home folder shortened to `~` and the full path on hover, Copy Path, and VoiceOver; then one status line. A live request says "Decide by" its deadline (time only, dim). A handed-back request says "Handed back with no decision · asked 2m ago" in text gray, from the arrival time, because Herdly records no hand-back time. The raw request sits behind "Show full request" only when it holds something the card does not already show. Other cards add the exact turn's working directory as the same dim "in" line. The notification's own prompt or question, current status, and valid actions follow in reading order; a completion ends with its bounded final-response preview. Technical identities, transport routes, and duplicated state or source labels stay out of the interface. The full queue retains its compact treatment.

## Layout

The panel is one column, left-aligned, centered on the display. On a display with a camera housing the collapsed strip is the housing row itself: exactly the housing height, anchored to the top edge of the screen, with one sprite per session (at most three, each in its own color; the unlit sprite while there is none; further sessions appear only in the open queue) and the count in a 112pt wing left of the housing and the Codex weekly limit readout (a 4pt by 14pt vertical bar, well track filled in Codex blue from the bottom, with the percent in ink beside it; an empty track and a dim dash when unknown) in a 60pt wing right of it (the name is read in the open queue); while Codex also reports a five-hour window, the same readout with a dim "5h" caption sits 8pt ahead of the weekly one and that wing is 112pt, the left wing unmoved; while a Claude root reports current windows, the newest reading's "5h" and "7d" readouts, filled in Claude orange, sit ahead of Codex's, 12pt from the Codex group, and the wing grows 62pt per Claude readout (room for "100%") plus that 4pt group gap (`UsageStripReadouts.wingWidth`); the open queue grows downward from that row. Elsewhere the strip is inline with the menu bar row, as tall as the bar and anchored to the top edge, or, on an external monitor showing no menu bar (a full-screen app), 40pt tall and tucked above the screen edge and slid in only while the pointer touches the top edge, the panel is hovered or focused, or a new item is spotlit. Its frame is the body width plus two 8pt ears. Collapsed, the body is the two wings plus the housing width (never narrower than 200pt); open, it is 60pt wider than collapsed, split evenly between the two wings so the housing stays centered (`NotchPlacement.expandedGrowth`; on a display without a housing the left wing takes it), and never narrower than 380pt; open, the left wing holds one sprite and the badge reads "N to check" (see Badge); the Wide and Extra wide panel widths grow it by 160pt or 260pt instead, never narrower than 480pt or 580pt, and never past 16pt from either side of the display (`PanelWidth`); it becomes exactly as tall as its content, capped at 480pt with the queue scrolling inside. On a display without a housing the same shape appears as a compact top-center strip.

Content is inset 16pt from each side of the frame (ear plus 8pt). In the strip the first sprite sits 4pt in from the inset, the sprites and badge follow at 6pt gaps, and the usage readouts are pushed to the right edge of their wing. The open queue begins with the seam, 12pt above the first row. Each row's heading line is 26pt tall, so one-line rows stack edge to edge; a row with details below its heading keeps 8pt under them. Inside a row, the title line, any sentence, the detail table, and the control row stack at 8pt (counted from the heading text); the detail table's own lines sit at 3pt. Every headed run of rows (a State, Agent, or Project group, or a kind section) sits 16pt from the next, its heading 2pt above its first row (#314). Detail labels occupy a fixed 58pt column with an 8pt gutter, so values align as a grid. Controls sit in a row at 6pt gaps. A 14pt bottom pad closes the queue.

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

Inside, every corner is continuous (SwiftUI `.continuous` style) and small: 4pt on the badge, 5pt on controls, 6pt on the focus ring that sits 2pt outside a control. The sprite is the only hard-edged shape: a bitmap of at most 9x5 cells at 2pt per cell, at most 18x10pt, with no anti-aliased corners.

## Components

### Buttons
Text-only wells in the panel's own vocabulary. No icons.
- **Shape:** continuous 5pt corners; 4pt vertical and 8pt horizontal padding.
- **Default (`button-notch`):** well background, ink label, 11pt regular. Used for "Open Session", "Deny", "Dismiss".
- **Emphasized (`button-notch-emphasized`):** same well, label in 11pt semibold. Used once per approval row, on "Approve once".
- **Pressed:** background inverts to ink, label to black. No scale, no spring.
- **Focus:** a 1.5pt ring in ink at 90% opacity, 6pt continuous corners, 2pt outside the control. Visible whenever the control has keyboard focus.
- **Disabled:** label drops to dim and the whole control to 60% opacity.

### Question card
The body of a question row, for Codex and Claude alike. One question is read at a time.
- **Step rail** (several questions only): a 2pt bar per question at 4pt gaps, the question's header beneath in 10pt. The current step is ink, an answered step dim, an upcoming bar a well with a dim label. When the headers do not all fit whole, the rail keeps only its bars and names the current question beneath them with "N of M" in dim, so no header is cut.
- **Answered lines:** each earlier question with an answer Herdly sent or drafted, as a detail-table line (header in the 58pt label column, answer in text gray).
- **Question:** 12pt regular in ink, wrapping in full. A single question's header sits above it in 11pt dim.
- **Options:** full-width option wells stacked at 4pt, each with its digit in a 14pt slot in the session's highlight and the label in ink. Options that are not pressable here keep the same digit slot, dim, with the label in text gray.
- **Later questions:** behind "Show the next question" / "Show the next N questions", as reference questions.
- **Read-only card:** when Herdly cannot answer, one 12pt ink sentence says where to answer ("Claude is asking 3 questions. Answer them in Claude."), followed by the questions as reference: header in the label column, question in ink, numbered options in text gray. Several questions sit behind "Show questions". The warning is never repeated per question.

### Badge
The count of items to check, hidden at zero, collapsed or open (D22). Collapsed it is the bare number ("3"); while the queue is open it names itself ("3 to check") in the room the open panel adds to the left wing (D2, D3; #318). Sessions beyond the three sprites are never counted on the strip.
- **Style:** well background, ink digits in 11pt medium tabular figures, continuous 4pt corners, 16pt minimum square with 2pt horizontal padding; the named badge keeps that style with 4pt horizontal padding (`badge-named`).
- **State:** none. It counts; it does not blink or change color.

### Sprite
The one picture in the system and the working signal. The user picks one animal for each display profile, and every session draws it in its own colour, in the strip and at the head of each queue row.
- **Kinds:** Sheep (default, 9x5 cells), Critter (6x4), Sheepdog (9x5), Cow (9x5), and Blob (7x5), each copied cell for cell from its Paper sprite artboard (`SpriteKind`). Each is two frames at 2pt per cell, drawn at its own size, at most 18x10pt, so three fit the 112pt left wing at 6pt gaps.
- **Form:** body cells in the session's body colour, highlight cells in its highlight.
- **Working:** alternates its two frames every 0.5 s. Under Reduce Motion it holds frame one and breathes in opacity between 50% and 100% on a 2.4 s cycle.
- **Idle:** frame one, still. Hidden from accessibility; the strip's label speaks for it.
- **Unlit:** the mark of an empty notch, shown while no session is listed. The chosen kind's frame one with every cell in well gray, so the highlights close into the body; still, with no step or breathe, and no session's color, so it never reads as a session. It sits where the first sprite would.
- **Placement:** leads the strip; leads every row title in the open queue except a folded Earlier result. It steps only while that session is working.
- **Slot:** in the open queue the sprite sits in a fixed 18x10pt slot, leading-aligned and centred vertically, with the title 6pt after it, so titles line up whichever kind is chosen. The slot's bottom sits on the title's baseline.

### Strip
The collapsed reading and the header of the open panel.
- **Layout:** 40pt tall; sprite, then task name 18pt to its right in 12pt regular text gray (one line, tail-truncated), then the badge at the far right.
- **Left wing** (user option):
  - **Sprites and count (default):** as described in Layout: up to three sprites and the bare count collapsed. Open, one sprite (the first working session's while any session works, so it steps, even when that session ranks below the three; otherwise the top-priority session's; the unlit sprite while none is listed) and the named badge, "N to check" (`StripWing`). That sprite is always in the colour its queue row uses.
  - **Count only:** keeps the badge and drops the sprites. While any session is working, one stepping sprite (the first working session's, in the colour its queue row uses) sits before the badge, so the working signal is never lost. Open, the badge reads "N to check".
  - **None:** leaves the wing empty, so the strip is a quiet black shape. Hovering still opens the queue, and a new item still spotlights.
- **Center label** (external displays only): Task name (the top-priority item's task name), Session name, or Off.
  - It is drawn in 12pt regular text gray, one line, tail-truncated, centred between the wings.
  - On a display with a camera housing it is never drawn, because the housing covers the space.
- **Usage bars** (user option): Compact (default), Weekly only, or Hidden. Weekly only drops the "5h" readouts of both sources and keeps Claude's seven-day and Codex's weekly readout, both without a caption since each is weekly; the fill hue tells them apart, and the right wing narrows to match. Hidden removes the readouts and shrinks the right wing to its minimum width.
- **Interaction:** the whole strip is a plain button that expands the queue; keyboard focus draws the ink ring around it (6pt corners, 1.5pt, 6pt outside horizontally).

### Group headings
With grouping on (State, Agent, or Project), the open queue inserts a heading above each group.
- **Text:** the group name ("Needs you", "Done", "Working"; the agent name; or the project folder's last path component).
- **Style:** 10pt caption, dim, 2pt above the group's first row's 26pt heading line; groups sit 16pt apart. This rhythm is the same for every heading: State, Agent, and Project groups and the kind sections below. No rule or line is drawn.
- **Sorting:** groups keep queue priority, so a group holding a live approval comes first. Rows sort inside their group.
- **"Earlier":** stays a heading inside whichever group holds the older completions, followed by the number of Earlier rows in that group in 11pt dim, folded ones included. A "Dismiss all" button sits at the heading's trailing edge and dismisses exactly the results it counts.
- **Kind sections** (no grouping; D13, agreed 2026-10-21, #314): rows that need the user sit under "Approve", "Answer", and "Check", each in 10pt dim with its count 6pt after it in 10pt semibold text gray, inset 6pt; an empty section has no heading. They replace the "Needs you" heading. When nothing needs the user, the unfolded running rows sit under "Working" with their count in the same style (#319, F1–F3, agreed 2026-10-21); it never folds behind "+N more". A card is never sectioned.
- **"+N more":** a later section shows its first rows and folds the rest (`QueueFold`: 11 lines below the strip, one per live approval, which never fold; at most three rows and a pill per folded section, the last taking what is left; never a single row folded). The pill is 10pt text gray on a well with 4pt corners and 6pt by 1pt padding, 2pt under the section's last row and indented to the title (sprite slot plus 6pt). It is a plain button with the ink focus ring, spoken "Show 5 more in Answer", and opens the rest of its section in place. Folds close whenever the panel opens.
- **Working fold:** while any row needs the user, running rows sit below them behind one disclosure, "N working" (11pt text gray, chevron, ink focus ring), closed whenever the panel opens. With State grouping the fold stands in for "Working". With nothing needing the user, running rows show unfolded, under the "Working N" kind-section heading when the queue is not grouped. Inside or outside the fold, a running row is its header line alone until it is opened (#319, F1–F3, agreed 2026-10-21).
- **Folded Earlier row:** one line: a chevron, the session name in 11pt text gray, and the result's exception word when it has one, with the age lane on the right. The fold is a plain button with the ink focus ring; opening it restores the full row header and shows the details and controls.

### Cards / Containers
Rows are not cards. There is no card surface, border, or shadow; a row is a left-aligned stack on the black ground, separated from its neighbors by 14pt of whitespace. The one exception is the opened running row below (#319, F1–F3, agreed 2026-10-21).
- **Running row** (#319, F1–F3, agreed 2026-10-21): in the open queue a running row is its row header alone; no body, disclosures, or controls. Clicking the header (a plain button; VoiceOver "Open details: <heading>", expanded or collapsed) opens it in place, and only one is open at a time: clicking another moves the open state, a second click or Escape closes it, and it closes when the panel collapses, its turn leaves the queue or stops working, or the "N working" fold closes over it. The open row is one container: #1A1A1A with 6pt continuous corners, 6pt outside the row's edges so the header does not move, wrapping the header and its details. The details are inset to the title (sprite slot plus 6pt), with 4pt above, 8pt below, and 6pt between lines. Each line is a 40pt label column ("now", "you", "where") in 11pt dim, 10pt gap, then the value in 11pt mono at a 16pt line height: "now" in ink ("$ " and the command for a shell command, otherwise the tool name and its target; "Unknown" in dim when neither an action nor a prompt is known), "you" and "where" in text gray ("you" the last prompt, "where" "Codex CLI", "Codex Desktop", or "Claude Code" then " · <terminal>" when Herdly last saw the session's host). A line with nothing to show is left out. A value longer than 80 characters or one line ends in "…"; a shortened action keeps "Show full command" (or "Show full action") under its line. The last line, 4pt lower, has "› Show full prompt" (or "Show more of prompt" with the "Shortened" note when Herdly kept only the prompt's start) on the left and the "Open" well (11pt semibold) on the right, still spoken "Open Session: <subject>"; a reason line replacing Open, Set up Ghostty, and Claude's Remove keep their places. Opening and closing use the queue's curve, a crossfade under Reduce Motion.
- **Row header** (D17, D21, agreed 2026-10-21, #314): one 26pt line at 8pt gaps: the session's mark in its 18pt slot with the name 6pt after it in 12pt semibold ink; then "· repo @ branch" (or the profile's label format) in 11pt dim when Herdly has seen the session's working directory, taking the free width and tail-truncating first so the name and word stay whole; then at most one word; then the age lane on the right in 11pt dim tabular digits (at least 36pt wide, right-aligned, refreshed every 30 s; "—" for a status-unavailable row), aligned on the first baseline. The row names no source and carries no kind tag; the section heading says the kind. The spotlight uses the same header without "Ns left".
- **Exception word:** "Failed" in 10pt ink on the failure well (4pt corners, 6pt by 1pt padding); "Handed back", "Waiting", and "Status unknown" in plain 10pt dim, with no well. Approve, answer, check, stopped, and working rows have none.
- **"Ns left"** (live approvals in the open queue only): "18s left" in 10pt semibold ink on a well with 4pt corners and 6pt by 1pt padding, with a 2pt ink bar pinned to its bottom-left edge, as wide as the share of the request's own window left and clipped to the pill. It steps once a second without animation and never moves the deadline. VoiceOver reads "18 seconds left" with the row heading.
- **Sentence (when present):** 11pt text gray, wrapping in full.
- **Detail table:** label column 58pt wide in dim, values in text gray, 8pt gutter, 3pt line spacing; missing values read "Not provided by Codex" in dim. Command and reason are selectable.
- **Disclosure:** "Show full request" in 11pt text gray reveals the long text inline. An opened running row's shortened shell command opens with "Show full command"; other tool actions keep "Show full action" (D11). Its "Show full prompt" reveals the full prompt below the last line and reads "Show less" while open (#319, F1–F3, agreed 2026-10-21). A Waiting row keeps its two-line prompt, which "Show full prompt" grows in place.
- **Controls:** a row of wells at 6pt gaps beneath the details.
- **Foot (full queue only):** the keyboard hint in 10pt dim, 2pt above the 14pt bottom pad.
- **Row note:** after the user approves, denies, or answers from the notch, the row's dim "· project @ branch" (a question row's dim place) is replaced by the note in the same 11pt dim ("Sending…", "Claude got your approval", "Sent, not confirmed", "Not delivered · answer in Claude", "Sent, waiting for Codex") until that request clears. "Not delivered" adds the row's Open well beneath the header. VoiceOver still reads the place, then the note, then the state.
- **Selected row (keyboard):** Up and Down arrows move one selection over the open queue's rows in reading order (a closed working fold and rows folded behind "+N more" are skipped; Tab reaches "+N more"). The selected row carries the focus ring's vocabulary around the whole row: 1.5pt ink at 90%, 6pt continuous corners, 6pt outside horizontally and 4pt vertically; VoiceOver adds the selected trait. Return on a selected approval or question opens its clicked card; Return on a selected running row opens or closes it in place (#319, F1–F3, agreed 2026-10-21). The ring wraps an opened running row's whole container. Tab still moves through controls.
- **Clicked card:** clicking an approval or question row's header opens that row alone with the spotlight body (see Spotlight detail) under a "‹ Queue" well at the top of the panel; no stepper, no arrows to other items. Approve, Deny, or Send returns to the queue at once; a question answered one typed key per question stays open until the key for its last question. Escape returns to the queue first, then collapses.
- **Empty queue:** with nothing listed, the open queue holds one row in the same grammar (`EmptyQueueReading`). The unlit sprite leads a 12pt semibold ink title. "Nothing running" is followed by a dim line naming the connected sources ("Listening for Codex and Claude."), or by no line while setup is still being checked. "Not connected" appears only once both setups are checked and neither is connected; a text-gray line ("Codex and Claude aren’t reporting to Herdly yet.") and an Open Controls well follow it. The strip's spoken label reads the same title.

### Panel motion
- **Resize:** the frame animates to its new size over 0.18 s with an ease-out curve; no spring, no overshoot. Under Reduce Motion, or before first presentation, the frame is set without animation.
- **Rows:** open-queue rows keep their identity, so a reorder slides each row to its new place over 0.28 s on a smooth curve with no bounce. A new row fades in from 6pt above at 98% scale; a leaving row fades and shrinks toward its top edge while the rows below close the gap. Group headings and "+N more" move with their rows, and opening "+N more" brings its rows in with the same transition. Under Reduce Motion rows, headings, and pills only crossfade over 0.15 s, with no offset or scaling. The "Ns left" bar steps each second and is never animated.
- **Hover hold:** the panel treats the pointer as inside for 0.3 s after it leaves, so a slip off the edge does not snap it shut.
- **Spotlight:** a new completion or actionable approval opens only its own row for 3 s; interaction holds it open and the original deadline applies afterward.
- **Clicked card:** opening a card from the queue, and ‹ Queue or Escape back, use the same row motion: the other rows leave and return with the row transition, and the frame resizes on the panel's curve. Under Reduce Motion both are the 0.15 s crossfade and an unanimated resize.

## Do's and Don'ts

### Do:
- **Do** draw every surface on pure black (#000000) and let the panel fuse with the menu bar; no window shadow, no rim.
- **Do** use the system monospaced face for every glyph, at 12pt semibold for titles, 12pt regular for the strip name, 11pt for body and controls, 10pt for the single hint.
- **Do** make every pressable thing a #2a2a2a well with continuous 5pt corners (4pt for the badge), and invert it to #e6e6e6 with black text when pressed.
- **Do** keep the ink/text/dim ladder: titles and digits in ink, readings in text, labels and identifiers in dim.
- **Do** show a 1.5pt ink ring at 6pt continuous corners on any control with keyboard focus.
- **Do** wrap commands and reasons in full; align the detail table on a fixed 58pt label column.
- **Do** animate frame changes with a 0.18 s ease-out and honor Reduce Motion by dropping the animation and switching the sprite to its breathe.
- **Do** keep a working signal visible in every configuration: the sprite steps at 0.5 s, whichever kind is chosen. A row is still when idle, and the mark is unlit when no session is listed.

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

The Settings window follows the native macOS conventions measured on macOS 26 (Tahoe). It does not use the notch's materials. Its reference mockup is the "Herdly Settings" Paper file.

- **Opening:**
  - From "Settings…" (⌘,) in the app menu, and from "Show Herdly controls" in the menu bar item.
  - The window title is the name of the selected pane, and the window reopens on the last pane viewed.
- **Structure:**
  - The window opens at 820x780pt, with a minimum of 720x600.
  - A fixed 210pt sidebar panel, inset 8pt, runs the full window height with 18pt continuous corners. The window buttons sit inside its top edge, and it never collapses.
  - The title bar is an empty unified toolbar 52pt tall, so the buttons line up with each pane's 15pt semibold title row.
  - Grouped sections fill the detail area.
  - Sidebar panes in labeled groups: "Notch" (General, Notch, Notifications), "Connections" (Agents, Terminals), then About on its own. There is no sidebar collapse button.
  - Each sidebar row is 32pt tall with a 20pt colour tile holding a white SF Symbol: gray gear, black sprite, red bell, purple sparkles, dark terminal, blue info.
  - The Notch tile shows the chosen sprite in green, the one place the notch's colour appears in the window.
  - The sidebar footer shows the "N working · N to check" status in 11pt secondary text.
- **Forms:**
  - `.formStyle(.grouped)` with system fills. Sections have 12pt continuous corners; rows are 36pt, or 40pt with a segmented control. Separators are inset 10pt.
  - Section headers are 13pt bold. Where a pane has footers, explanations go there in 11pt secondary text; Notifications and Terminals have none.
- **Controls:**
  - Mini switches for booleans, menu pickers for lists, and segmented pickers for two or three short choices.
  - Push buttons for actions. Destructive actions sit alone in the last section, end in an ellipsis, use the destructive role, and confirm first.
- **Colours:**
  - **Dark mode:** a near-black tint closer to the notch. The window and pages are 7.5% white (#131313) and sections are 12.5% white (#202020).
  - **Light mode:** keeps the system values (white window, #F9F9F9 sections).
- **Behaviour:** every change applies immediately. There is no Apply, OK, or Cancel button.
- **Motion:** every click answers within half a second.
  - Pages crossfade and rise 10pt as you switch panes.
  - The preview, sprite tiles, sound tiles, and disabled rows ease to their new state over 0.4 s.
  - Pressed tiles and rows dip to 97%.
  - Reduce Motion keeps only a 0.15 s crossfade with no movement or scaling.
  - Unlike the notch, the Settings window may use the system's smooth easing.
- **Sound:** switching panes, segments, or sprite tiles plays a soft click (the system "Tink" at 30% volume). It follows the macOS "Play user interface sound effects" setting. The notch never clicks.
- **Notch pane:**
  - A segmented "MacBook notch | External display" picker in the toolbar chooses which profile is being edited.
  - A live preview of the strip on a desktop backdrop sits above the sections and redraws as options change.
  - Options that do not apply to the selected profile, such as Center label on the MacBook notch, are shown disabled with a footer saying why.
- **Sprite picker:** a "Sprite" section with no footer holding five equal-width tiles in a row at 10pt gaps: Sheep, Critter, Sheepdog, Cow, and Blob. Each tile is a 76pt black well with 9pt continuous corners and the kind's idle frame centred at 6pt per cell in the first session colour, with its 12pt name 6pt below. The selected tile has a 2pt accent ring with a 2pt gap and a medium-weight name. Each tile is a button named for its kind.
- **Agents pane:**
  - One card per agent with no section header above it, 28pt apart: Codex, then Claude Code. The Claude Code card describes the default folder; each added folder is a row in that card with its monospaced path, status, a Configure button while it needs setup, and its own ⋯ menu (Review Again, Show Setup Changes…, the two switches as menu items, Undo Setup…, Remove Folder). Its problems sit indented beneath it.
  - The 52pt header row holds a 28pt tile with 7pt corners (Codex: near-black with a white `terminal` symbol; Claude Code: #D97757 with a white `sparkle`), the 13pt semibold name over an 11pt secondary subtitle, the status dot and text (green Connected, orange Restart required or another short reason, gray Checking until the first detection), a Configure button while setup is needed, and a 22pt borderless ⋯ menu.
  - Subtitles: Codex lists each surface ("CLI 0.150.0 · Desktop 26.1015", or "Desktop not installed"); Claude shows "version · folder".
  - The card's ⋯ menu holds Review Again, Show Setup Changes…, Add Another Claude Folder… (Claude), then Undo Setup…. Items appear only when they apply today. Its VoiceOver label names the agent, and the folder for Claude.
  - Show Setup Changes… opens a sheet with the exact, selectable monospaced preview and a Done button (Return or Esc).
  - A problem row appears only when something needs fixing: label left, an orange dot and the fix right, such as "Codex desktop · Update to 26.901.51231 or later". A missing surface is not a problem while the other is supported.
  - Claude's rows: "Usage limits on the strip" (the current "5h 32% · 7d 61%" reading before the switch, "Unavailable" when no window is current, or, with an orange dot, why usage cannot be read) and "Name sessions with Haiku", without descriptions.
  - The last setup action's result stays in its card as secondary text until replaced, so a failure stays readable. Terminal status lives in Terminals, not here.
- **Notifications pane:**
  - "Sound": one card with a "Completions and questions" mini switch, an inset divider, then the sound tiles. "Completions": one card with a "Clear when read in Codex" mini switch and no description. While that switch is on and Codex's read state cannot be read, a 12pt problem line with an orange dot sits under it; the switch's tooltip carries the latest read-state status.
  - Below the cards, right-aligned 6pt lower: a "Send Test Notification" push button, with "Dismiss" before it only while the test notification is showing.
  - No footers.
- **Sound tiles:**
  - Every macOS system sound as a 120x28pt tile in a leading-aligned wrapping grid with 6pt gaps and 10pt padding inside the card. Tiles have 7pt continuous corners and 13pt names.
  - Unselected: primary at 4% (#0000000A in light mode) with regular primary text. Selected: an accent fill with white medium text. No check mark, play button, or Default label; Glass is the default selection.
  - Choosing a tile selects it and plays the sound once; it eases over 0.4 s and dips to 97% when pressed. While sound is off the grid is disabled at 50% opacity.
  - Each tile is a button named for its sound, with the selected trait when chosen, and reachable with Tab under full keyboard access.
- **Terminals pane:**
  - "Terminals" and "Multiplexers", each one card holding a row per shown app, with 10pt inset dividers between apps.
  - A row is at least 38pt tall with 10pt spacing: the 13pt name and an 11pt dim version (primary at 40%) on one baseline 6pt apart, then the status pill, the mini switch, and a 22pt borderless ⋯ menu.
  - Status pill: 11pt medium text, 7pt by 1pt padding, 5pt corners. Ready is green text on 12% green, Needs attention orange text on 12% orange, Not in use and Off secondary text on primary at 6%. A small spinner stands in while herdr's first scan runs. VoiceOver reads "Status: X".
  - The ⋯ menu holds Show Diagnostics… (the exact, selectable monospaced reasons in a sheet; disabled when there are none) and How Open Works… (the app's targeting rule and Open fallback as plain text in a sheet). Both sheets close with Done, Return or Esc. VoiceOver names the menu "<App> actions", and the switch "Enable <App>".
  - Problem lines sit under their row with no divider between them, 12pt with an orange dot, 10pt above the next divider. A denied Automation permission ends its line with a small Open Settings… button; a herdr command follows its line in 12pt monospace with a Copy button.
  - No footers, and no separate Version, Permission, or Status rows.
  - Reduce Motion keeps only the crossfade.

## Question cards — Paper redesign

The [Paper reference](https://app.paper.design/file/01M51985RZGVMFW23BNQWAFNY5/p-1-0), accepted on 2026-10-16, supersedes the earlier question-card composition. It applies to Codex and Claude, in spotlight and the full queue. Other card types and the shared strip retain their existing typography and layout.

Question cards use bundled JetBrains Mono Regular and SemiBold (v2.304, OFL-1.1), at 10pt for rail headings and recommendation labels, 11pt for options and metadata, and 12pt for the session heading and question. The reference's 560pt body is a visual comparison size, not a replacement for the user's Standard/Wide/Extra wide setting. Keep the existing session color and chosen sprite; the reference's amber is one session, not a global accent.

Reading order: session heading with project/branch and age; source and working directory; question rail with answer summaries; the viewed question; full-width option wells; typed answer when supported; navigation left and Open Session/Dismiss right. Use 14pt section gaps, 10pt question-to-options spacing, 4pt option gaps, 8pt horizontal/7pt vertical option padding, and 5pt control corners. The shared panel retains its placement contract and housing shape. Real metadata alone populates the heading; missing fields are omitted.

The viewed rail segment is bright. Earlier answers live beneath their segment heading; an editable unsent draft offers `change`. Long content wraps, and the rail stacks when its headings cannot fit horizontally. `Recommended` is separated from an exact trailing ` (Recommended)` in an agent-supplied label for display only; the original label remains the answer sent. Selection uses the session body color and black ink, with a spoken selected value. A reviewed terminal answer stays selected but cannot be pressed or typed over. Unknown, unavailable, and unconfirmed states retain their explanations.
