# Rendering model

## Core principle

The letter polyline (in `PrimaeNative/Resources/Letters/<L>/strokes.json`)
is the **pen centerline** of the letter, in bbox-relative coordinates
[0, 1]. It is size-agnostic, instrument-agnostic, and width-agnostic.

The renderer is responsible for turning it into pixels.

## What the polyline is

For each letter, a sequence of strokes. Each stroke is a polyline of
2D points. The polyline traces the path a pen would have taken to
produce that letter shape — its centerline, not its outline.

The polyline:
- Has endpoints at the visual corners of where the pen lifts (e.g. M's
  BL, BR; each leg of N).
- Has filleted interior joints at intra-stroke turning points (e.g. M's
  peaks and valley) with fillet radius matching the local stroke
  half-width of the source font. The fillets are part of the
  centerline geometry, not added by the renderer.
- Does NOT carry stroke-width information. Width is a render decision.

## What the renderer does

The renderer takes a polyline and produces visible output. Two things
to set per render context:

### Letter size

Multiply bbox-relative coordinates by the target render size. A 10cm
letter and a 1cm letter use the same polyline — only the multiplier
changes.

### Stroke width (independent of letter size)

Pick an absolute stroke width based on context — NOT proportional to
letter size. A child's pen produces a ~1-2mm mark whether they write
1cm letters or 10cm letters. Computer fonts scale uniformly in all
dimensions; pen-on-paper does not.

Suggested widths (concrete values are placeholders; adjust to feel):
- **Display glyph for tracing** — ~3-4mm. The Prima-style thick gray
  letter the child traces on top of.
- **Finger trace render** — same as display, ~3-4mm. Finger touches
  are broad; the rendered mark should match.
- **Pencil trace render** — ~1mm. Apple Pencil tip is narrow; the
  rendered mark should match the physical instrument.

Stroke the polyline with `lineCap: .round` and `lineJoin: .round`.
Rounded caps at endpoints produce the visible letter terminals; the
filleted joints in the polyline data combined with round line joins
produce smooth peaks/valleys.

## Scoring (separate from rendering)

What "correct trace" means depends on input device.

### Finger
Lenient. Glyph-containment scoring: the finger mark stays within the
display band. Drift within the band is fine — finger touches are
exploratory.

### Pencil
Precise. Centerline-distance scoring: pencil tip distance to the
polyline centerline, with tolerance ~50% of the display band's
half-width. Outside that tolerance counts as off-track. Encourages
following the path, not edge-tracing.

The polyline supports both scoring modes without modification.

## Calibrator vs gameplay

`StrokeCalibrationOverlay.swift` is a diagnostic view used during
authoring. It currently shows the font's outline (ink letter) with a
thin red polyline overlay. This is correct for authoring but is NOT
the gameplay rendering — the gameplay view should stroke the polyline
thick per the principles above, not render the font's outline.

When debugging discrepancies between calibrator and iPad gameplay,
keep this distinction in mind:
- Calibrator: font outline + thin polyline overlay (authoring view)
- Gameplay: polyline stroked thick at constant absolute width
  (production view)

## Why this matters

Several architectural debates during phase 1 turned on confusion
between these two views. "The trace endpoint sits inside the ink"
looks short in the calibrator because the polyline is thin and the
ink is the font outline. The same polyline stroked thick with rounded
caps produces a visible letter terminal at the corner — the cap
center sits where the polyline ends, the cap edge reaches the corner.
This is geometrically correct and is the intended gameplay rendering.

## Open questions for renderer implementation

- Default display band width and how it scales between finger / pencil
  modes (smooth crossfade vs hard switch on input-device detection).
- Whether mid-stroke device change is supported.
- Tolerance band tuning for pencil scoring — start at 50% of display
  half-width and adjust based on user testing.
- Whether the display glyph should fade out as the child traces over
  it (typical learn-to-write app behavior) or remain visible
  throughout.
