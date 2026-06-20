# Primae Design System

A design system for **Primae** — an iPadOS handwriting‑learning
app for German‑speaking 5–6 year‑old Austrian Volksschule first‑graders.

> *Primae* (Latin: "the first ones") — the child's first letters, the first
> strokes of school cursive, the first taste of literacy. The name is also
> the bundled display typeface.

The child traces a letter on the iPad through a four‑step pedagogical flow
(observe → direct → guided → freeWrite). Audio playback time‑stretches with
writing velocity, haptics fire on checkpoint hits, and an on‑device CoreML
model recognises the freely‑written letter at the end. Parents/teachers
unlock a research dashboard with a 2‑second long‑press on a hidden gear
icon; children can never reach those screens by accident.

## Sources

This design system was reverse‑engineered from a single comprehensive
technical spec (no screenshots, no Figma, no live build):

- **Spec doc** — `https://github.com/TheDave94/Primae/blob/main/docs/APP_DOCUMENTATION.md`
  (master's‑thesis technical foundation; the source of truth for
  architecture, pedagogy, copy strings, and canvas semantics).
- **Repo README** — `https://github.com/TheDave94/Primae`. Useful for
  the demo letter set (A F I K L M O) and the velocity‑driven audio idea.

Specific colour hexes, spacing scales, surface tints, type ramps, and
component layouts are **derived choices** rooted in the documented
canvas semantics (blue ghost strokes, green child ink, orange guide
dot) and Austrian schoolbook visual context. Where a value isn't pinned
by the doc, the choice is annotated inline in `colors_and_type.css`.

## Index

| File / folder | What's in it |
|---|---|
| `README.md` | This file — content & visual fundamentals, iconography, manifest |
| `colors_and_type.css` | All design tokens (CSS vars) + semantic type classes |
| `fonts/` | Webfonts (Playwrite AT bundled; Primae substituted with Nunito — see Caveats) |
| `assets/` | Logos, world icons, illustrations, app glyph |
| `preview/` | One small HTML card per token cluster — populates the Design System tab |
| `ui_kits/ipad-app/` | React/JSX recreation of the four‑phase tracing flow + worlds + parent area |
| `SKILL.md` | Cross‑compatible Agent Skill front‑matter |

## Content fundamentals

**Audience split.** Two voices coexist in the app and they are clearly
separated.

- **Child voice (German, second person, lowercase warmth)** — used in
  every prompt the child can see or hear. It is short, instructive, and
  always positive. It addresses the child as "du" (informal you) and
  uses present‑tense action verbs at the start of the sentence so the
  child knows what to *do* before any adjective lands.
  - "Schau mal genau hin." — pay attention now.
  - "Tippe die Punkte der Reihe nach." — tap the dots in order.
  - "Jetzt fährst du die Linien nach." — now you trace along the lines.
  - "Jetzt schreibst du den Buchstaben ganz alleine." — now you write
    the letter all by yourself.
  - Praise after a star: **"Super!", "Toll gemacht!", "Weiter so!"** —
    short, never a number, never a percentage.
  - Trend pill words on the progress screen: **"aufwärts", "stabil",
    "abwärts"** (going up / steady / going down) — never "+12 %".

- **Adult voice (German, more clinical, parent‑gated)** — used in the
  Forschungs‑Daten / Einstellungen / Datenexport screens. Real
  metrics, real terminology, including academic loanwords:
  *Schreibmotorik, Studienteilnahme, Datenexport, A/B‑Arm,
  Spaced‑Repetition‑Effizienz, Pearson r, Schreibmotorik‑Dimensionen*.

**Tone.** Warm, calm, never patronising. There is no mascot, no fake
cheerfulness, no "Oops!" copy. The app respects that handwriting is a
real skill children work hard to acquire. Praise is earned, brief, and
always followed by **Weiter** ("continue") — the next thing to do.

**Casing.** German rules: every noun is capitalised
(`Schriftart`, `Übungsverlauf`, `Studienteilnahme`). Sentences end with
a full stop. Headings use sentence case in copy but display case
(German nouns capitalised) in titles.

**No emoji in copy** — except the three faces in the paper‑transfer
self‑assessment (😟 😐 😊), which are functional inputs, not decoration.

**No icons replacing words** — every action button has a German label.
Icons sit *next to* the word, never instead of it.

**Numbers.** Children never see numbers other than their star count
(0–4). Times, percentages, and Schreibmotorik dimension scores are
rendered only inside the parent‑gated dashboards.

## Visual foundations

### Surface system — "paper, not glass"

The app is staged on a single surface metaphor: a warm cream **paper**.
Cards are paper cut‑outs over a slightly recessed paper backing,
outlined with a 3 px ink border so they read as physical objects rather
than translucent sheets.

- **`--paper`** `#FDF8EE` — main canvas background (the page).
- **`--paper-deep`** `#F6EFDD` — subordinate surface behind cards.
- **`--paper-edge`** `#ECE2C8` — borders, tooltip surfaces, dividers.
- **`--canvas-paper`** `#FFFCF4` — the writing canvas itself, slightly
  whiter so the child's green ink and the blue ghost stroke pop.

There is **no glass blur, no translucency, no gradient backgrounds**.
The paper has no texture image either — flat fills only, with
generous radii (`--r-md` 14 px to `--r-2xl` 40 px) doing the friendly
work that an illustration would otherwise do.

### Stroke colour semantics (canvas, source‑pinned)

Locked by the spec; everything else hangs off these:

- **Ghost / reference stroke** — `--ghost` `#4A86C7`, opacity 0.40,
  line width 8.
- **Child ink** — `--ink-stroke` `#3FA060`, line width 4 (inside KP
  overlay) / 8 (active stroke). Reads as "your writing".
- **Animation guide dot (observe phase)** — `--guide` `#F08A2A`,
  pulses across the stroke at the canonical pace.
- **Numbered start dot** — `--start-dot` `#2A241A` (warm near‑black);
  the next‑expected dot pulses with a `--guide-soft` halo.

### Brand colour & world tints

The app has three top‑level "worlds". Each gets its own tint that
colours the rail icon, the active dot above the icon, and a subtle
header band on the world's hero screen.

| World | Tint | Soft tint | Icon | Use |
|---|---|---|---|---|
| **Schule** | `#4A86C7` (`--schule`) | `#DCE9F5` | book.fill | Guided 4‑phase tracing |
| **Werkstatt** | `#E0A234` (`--werkstatt`) | `#F8EBCC` | pencil.tip | Freeform writing |
| **Fortschritte** | `#C24A2C` (`--fortschritte`) | `#F5D8CC` | star.fill | Progress, stars, streak |

The brand‑level red (`--brand` `#C24A2C`) is the same hue as the
Fortschritte world — celebration red, also used as primary CTA.
Together with the schoolbook‑blue and the workshop‑yellow this gives
us a primary triad that maps cleanly onto pedagogy (calm/effort/
celebration).

### Type

Two voices map to two families:

1. **Primae** (Druckschrift / print). The bundled OTF is not
   redistributable, so this design system substitutes **Nunito** as
   the placeholder until the real font files are dropped into
   `fonts/`. Nunito's rounded humanist forms approximate Primae's
   "child‑readable" intent (unambiguous a/g/q, balanced stroke
   widths). **Flag this substitution to the user — see Caveats.**
2. **Playwrite AT** — Austrian school cursive (SIL OFL 1.1, variable
   TTF). Loaded from Google Fonts and used wherever the app would
   render Schreibschrift. This is the *real* bundled font.

Type scale runs from 13 px caption to 96 px display, with one extra
"glyph" size (220 px) for the giant traceable letter on the canvas.
Line height is generous (1.45 base) and tracking is slightly tight on
display sizes; it never goes ALL CAPS except on adult‑area eyebrows
(`--ls-caps` 0.06 em).

### Imagery

The app ships **no photography**. Letters are rendered live from the
font; per‑letter recorded audio is the only "asset" alongside fonts.
This design system therefore avoids inventing photography. Decorative
illustrations are limited to:

- a small **hand‑drawn‑feel pencil glyph** for the app icon,
- the three **emoji faces** for paper‑transfer self‑assessment,
- **stars** (filled and empty) for the reward system.

If marketing material is added later, the doc's tone implies
warm‑daylight Austrian classroom photography over stylised
illustration.

### Backgrounds

Flat. Always. No gradients, no patterns, no full‑bleed images. A
world's hero screen may have a 96‑px tinted band at the top
(`--schule-soft` etc.) bridging the sidebar tint into the content
area. That band is the *only* tinted surface; the rest is `--paper`.

### Animation

Three motion profiles:

- **Soft** (`--ease-soft` `cubic-bezier(.32,.72,.30,1)`, 200–320 ms) —
  the default for any UI move (panel open, card hover, button press).
- **Bounce** (`--ease-bounce`, 520 ms) — reserved for celebration
  moments only: a star landing, a praise badge entering, the level‑up
  popup. *Bounce is rare — overusing it makes the app feel toyish.*
- **Pulse** (`--ease-pulse`, 1.0 s loop) — used on the next‑expected
  numbered dot in the direct phase (and only there). Steady in/out,
  no scale spike.

Cross‑fades for phase transitions; no slide‑ins, no parallax. The
documented `--dur-arrow` 1200 ms direction‑arrow window is reserved
for the direct phase's stroke‑direction cue.

### Hover, press, focus

- **Hover** — opacity 0.92 + a 1‑px paper‑edge outline; never a colour
  shift. (Children don't hover on touch — this state only matters in
  the parent area on iPad with a Magic Keyboard pointer.)
- **Press** — 1‑px translateY(1px) + the sticker shadow `--sh-sticker`
  collapses to `--sh-press`. No colour change. The button
  *physically depresses* on the page.
- **Focus** — 3‑px halo in `--info` (the schule blue) at 4 px offset.
  iPadOS native focus ring style, not a custom one.

### Borders, shadows, elevation

The app uses a hard "ink line" border treatment that mimics a
schoolbook drawing:

- Cards: `--bw-3` (3 px) ink line + `--sh-2` soft drop shadow.
- Selected/active card: `--bw-4` (4 px) brand line.
- Buttons: 0 px border but a hard `--sh-sticker` (`0 4px 0` ink) so
  the button looks stamped onto the page; collapses to `--sh-press`
  on press.

There is **no inner shadow system**. There is no "frosted" or
"capsule‑with‑glow". The shadow palette caps at three levels (`--sh-1`
to `--sh-3`) plus the sticker treatment.

### Corner radii

Friendly but not toy‑round.

- Buttons & chips: `--r-pill` (full pill).
- Cards: `--r-lg` 20 px to `--r-xl` 28 px.
- Phone‑width sheets / parent dashboard sections: `--r-2xl` 40 px.
- Tooltip / inline label: `--r-sm` 8 px.

### Layout rules

- Fixed left rail at **64 px** width (the `WorldSwitcherRail`),
  full‑height, `--paper-deep` background, ink line on the right edge.
- Phase indicator is a fixed 4‑dot row at the top of the canvas world,
  centred.
- The canvas itself is centred and sized to the larger of 720×720 or
  60 % of the viewport's shorter side.
- Bottom right of every world: a circular **Weiter** ("continue")
  button when the world has a forward action.
- Parent area uses `NavigationSplitView` (sidebar + detail) — purely
  iPadOS native chrome; no custom split.

### Transparency & blur

Used **once**: the KP (Knowledge of Performance) overlay after
freeWrite darkens the canvas with `rgba(42, 36, 26, 0.55)` and
overlays the reference stroke (blue) and the child's path (green) on
top, so the child can see exactly where their trace diverged. No other
blur in the app. No glass.

## Iconography

The app is iPadOS‑native and uses **SF Symbols** throughout (the
documented icon names — `book.fill`, `pencil.tip`, `star.fill`,
`gearshape`, `chevron.right`, etc. — are SF Symbol identifiers). SF
Symbols are not redistributable, so this design system substitutes
**Lucide** (CDN: `https://unpkg.com/lucide@latest`) — same outlined +
filled stroke logic, similar weight, neutral commercial license.
**Flag this substitution to the user.**

The mapping used in the UI kit:

| App SF Symbol | Lucide substitute | Used for |
|---|---|---|
| `book.fill` | `book-open` | Schule world |
| `pencil.tip` | `pencil` | Werkstatt world |
| `star.fill` | `star` | Fortschritte world; ratings |
| `gearshape` | `settings` | Parent area entry (long‑press) |
| `chevron.right` / `.left` | `chevron-right` / `-left` | Letter picker / nav |
| `play.fill` | `play` | Audio replay |
| `arrow.clockwise` | `rotate-ccw` | Restart letter |
| `xmark` | `x` | Dismiss |
| `checkmark` | `check` | Phase complete badge |

**No emoji as decoration.** The only emoji in the entire system are
the three faces (😟 😐 😊) used as functional inputs in the
paper‑transfer self‑assessment — these are kept as plain Unicode
characters, not images, so they render in the system's native
emoji font.

**No custom SVG illustration set.** Where the app needs a visual
beyond an icon (e.g. the app glyph), this design system provides a
single `assets/app-glyph.svg` of a stylised pencil drawing the letter
"B" on a paper square. All other "decoration" comes from typography
and colour.

## Caveats

The user MUST iterate with us on these — see the closing ask.

1. **Primae font is bundled** — the OTFs ship in `design-system/fonts/`
   and `PrimaeNative/Resources/Fonts/` (12 weights) under
   CC BY-NC-SA 4.0 (Nemeth/Tiefenthaler); see
   `PrimaeNative/Resources/Fonts/Primae-Font-CC-BY-NC-SA-4.0.txt`.
   (An earlier note here claimed the font was unbundled and the system
   substituted **Nunito** — no longer true.)
2. **No screenshots, no Figma** — every visual decision (paper hue,
   world tints, card shadow style, layout grid) is *derived* from the
   doc's text. The app's actual interface may differ in details.
3. **SF Symbols → Lucide substitution** — same intent, different stroke
   curvature.
4. **Public repo is the older C/C++ Timestretch** — the SwiftUI
   architecture in the doc may not yet be public source. The UI kit is
   based on the doc, not on read source files.
5. **Single‑product system** — the only "product" is the iPad app;
   there is no marketing site, no docs site, no slide template.

## SKILL.md

See `SKILL.md` for the agent‑skill front‑matter that lets this folder
double as a Claude Code skill (`primae-design`).
