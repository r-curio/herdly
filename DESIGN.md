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

Steer's only designed surface is a notch panel: a single pure-black shape that grows out of the bottom of the macOS menu bar as if it were part of the camera housing. It is read the way a gauge is read. Three readings sit on one line: a green 8-bit sprite that steps while Codex is working, the name of the task in a gray monospaced face, and a dark-gray count of items that need the user. Everything else lives one hover away and is drawn from the same three materials: black ground, gray type in a single monospaced family, and dark wells for anything pressable.

The world is deliberately austere. Color belongs to the sprites alone: each session has one of six sprite colors, chosen from its identifier so it stays with the session. There is one typeface, and it is the system monospaced face at 10 to 12 points. Depth is not a shadow; the panel has no window shadow at all, because a shadow rim would outline the shape and break its fusion with the menu bar. The only edge inside the panel is a one-point seam at eight percent white between the strip and the open queue. Motion is a reading, not an ornament: the sprite's two-frame step is the working signal, the frame resize is a short ease-out, and Reduce Motion replaces the step with a slow breathe and removes the resize animation entirely.

This is not the glossy dynamic island. It refuses glow, gradient, glass, the pulsing dot, and the spring bounce. It also refuses pictorial chrome: no glyph icons, no logo, no wordmark. The sprite is the one picture in the system.

**Key Characteristics:**
- One black shape fused to the menu bar: flat top, concave 8pt ears, deep 18pt bottom radii, no window shadow
- One monospaced face (SF Mono via the system monospaced design) at 10, 11, and 12pt; semibold only for titles and the emphasized action
- One color: the green sprite body and its lighter highlight; every other value is a gray on black
- Dark-gray wells (#2a2a2a) for the badge and every control; a pressed control inverts to light ink with black text
- Dense, left-aligned rows separated by whitespace, not lines; the single seam is the only rule drawn
- Motion carries meaning: a 0.5 s sprite step means working, a 0.18 s ease-out resize means the panel changed size

## Colors

An achromatic ladder on pure black with a single green, reserved for the sprite.

### Primary
- **Sprite Green** (`{colors.sprite}`): the sprite's body cells, and nothing else. It is the only chroma in the world; it appears in the strip, and again at the head of a "working" row in the open queue.
- **Sprite Highlight** (`{colors.sprite-light}`): the sprite's ear and eye cells. A lighter green that gives the 6x4 bitmap its read at two points per cell.

### Neutral
- **Ground** (`{colors.ground}`): the panel itself, pure black so it fuses with the menu bar and the camera housing. Also the text color of a pressed control.
- **Ink** (`{colors.ink}`): row titles, badge digits, control labels, the focus ring, and the fill of a pressed control. The brightest gray; reserved for what must be read first.
- **Text** (`{colors.text}`): the task name in the strip, detail values, and explanatory sentences. The reading gray.
- **Dim** (`{colors.dim}`): session labels, detail-table labels, the "Not provided by Codex" placeholder, the keyboard hint, and the label of a disabled control. Holds 4.7:1 on black, so tertiary never drops below legibility.
- **Well** (`{colors.well}`): the badge and every control at rest. The only surface tone other than black.
- **Seam** (`{colors.seam}`): a one-point line between the strip and the open queue. White at eight percent is the only edge drawn inside the panel.

### Named Rules
**The One Color Rule.** A session's colour belongs to its sprite, and the sprite lends it to exactly one other place: the answer options of that session's question, where the digit is drawn in the session's highlight and the option the user chose fills with the session's body colour under black text. No badge, title, ring, or other control carries hue; every other state is spoken through motion and gray. A question row is headed by its session's standing sprite so the colour on the options reads as "this session", never as a category.

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

## Layout

The panel is one column, left-aligned, centered on the display. On a display with a camera housing the collapsed strip is the housing row itself: exactly the housing height, anchored to the top edge of the screen, with one sprite per session (at most three, each in its own color), the "+N" overflow mark, and the count in a 112pt wing left of the housing and the Codex weekly limit readout (a 4pt by 14pt vertical bar, well track filled in ink from the bottom, with the percent in ink beside it; an empty track and a dim dash when unknown) in a 60pt wing right of it (the name is read in the open queue); the open queue grows downward from that row. Elsewhere the strip is inline with the menu bar row, as tall as the bar and anchored to the top edge, or, on an external monitor showing no menu bar (a full-screen app), 40pt tall and tucked above the screen edge and slid in only while the pointer touches the top edge, the panel is hovered or focused, or a new item is spotlit. Its frame is the body width plus two 8pt ears. Collapsed, the body is the two wings plus the housing width (never narrower than 200pt); open, it widens to 380pt and becomes exactly as tall as its content, capped at 480pt with the queue scrolling inside. On a display without a housing the same shape appears as a compact top-center strip.

Content is inset 16pt from each side of the frame (ear plus 8pt). In the strip the first sprite sits 4pt in from the inset, the sprites, overflow mark, and badge follow at 6pt gaps, and the weekly readout is pushed to the right edge of its wing. The open queue begins with the seam, 12pt above the first row. Rows stack at 14pt; inside a row, the title line, any sentence, the detail table, and the control row stack at 8pt; the detail table's own lines sit at 3pt. Detail labels occupy a fixed 58pt column with an 8pt gutter, so values align as a grid. Controls sit in a row at 6pt gaps. A 14pt bottom pad closes the queue.

No breakpoints and no grid beyond this: the panel is a single fixed-width column on every display.

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
- **Default (`button-notch`):** well background, ink label, 11pt regular. Used for "Open in Codex", "Deny", "Dismiss".
- **Emphasized (`button-notch-emphasized`):** same well, label in 11pt semibold. Used once per approval row, on "Approve once".
- **Pressed:** background inverts to ink, label to black. No scale, no spring.
- **Focus:** a 1.5pt ring in ink at 90% opacity, 6pt continuous corners, 2pt outside the control. Visible whenever the control has keyboard focus.
- **Disabled:** label drops to dim and the whole control to 60% opacity.

### Badge
The count of items to check, hidden at zero.
- **Style:** well background, ink digits in 11pt medium tabular figures, continuous 4pt corners, 16pt minimum square with 2pt horizontal padding.
- **State:** none. It counts; it does not blink or change color.

### Sprite
The one picture in the system and the only working signal.
- **Form:** a 6-column by 4-row bitmap at 2pt per cell (12x8pt). Body cells in sprite green, ear and eye cells in sprite highlight.
- **Working:** alternates two frames every 0.5 s (the feet step). Under Reduce Motion it holds frame one and breathes in opacity between 50% and 100% on a 2.4 s cycle.
- **Idle:** frame one, still. Hidden from accessibility; the strip's label speaks for it.
- **Placement:** leads the strip; leads a "working" row title in the open queue (offset up 1pt to sit on the baseline).

### Strip
The collapsed reading and the header of the open panel.
- **Layout:** 40pt tall; sprite, then task name 18pt to its right in 12pt regular text gray (one line, tail-truncated), then the badge at the far right.
- **Interaction:** the whole strip is a plain button that expands the queue; keyboard focus draws the ink ring around it (6pt corners, 1.5pt, 6pt outside horizontally).

### Cards / Containers
Rows are not cards. There is no card surface, border, or shadow; a row is a left-aligned stack on the black ground, separated from its neighbors by 14pt of whitespace.
- **Row header:** title in 12pt semibold ink on the left, session label in 11pt dim on the right, aligned on the first baseline with 10pt spacing; a working row leads with the sprite.
- **Sentence (when present):** 11pt text gray, wrapping in full.
- **Detail table:** label column 58pt wide in dim, values in text gray, 8pt gutter, 3pt line spacing; missing values read "Not provided by Codex" in dim. Command and reason are selectable.
- **Disclosure:** "Show full request" in 11pt text gray reveals the long text inline.
- **Controls:** a row of wells at 6pt gaps beneath the details.
- **Foot (full queue only):** the keyboard hint in 10pt dim, 2pt above the 14pt bottom pad.

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
- **Do** keep the sprite as the sole working signal: two frames at 0.5 s while working, still when idle.

### Don't:
- **Don't** put green anywhere but the sprite; no green badges, rings, titles, or status dots.
- **Don't** add a glow, gradient, glass, blur, border, or shadow to the panel or to any well.
- **Don't** use a spring, bounce, or overshoot on the panel frame, and don't pulse or blink anything.
- **Don't** introduce a second typeface, a display face, or a proportional face for prose.
- **Don't** add glyph icons, a logo, or a wordmark to the panel; controls are text-only wells and the sprite is the only picture.
- **Don't** truncate a command, reason, or detail with an ellipsis inside the open queue; only the strip name is one line.
- **Don't** draw rules or dividers between rows; the one seam under the strip is the only line in the panel.
- **Don't** document or reuse the developer controls window as a designed surface; it is outside this system.
