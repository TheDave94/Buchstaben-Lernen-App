CENTERLINE & STROKE INVARIANTS — read before any letter work

1. CENTERLINE LOCATION
   Every polyline point sits at the medial axis — the middle of the
   stroke width — never offset toward either border.

2. CENTERLINE SHAPE
   The centerline's overall shape mirrors the inner border (counter)
   of the glyph, not the outer silhouette. For asymmetric bands (D
   bowl, P bowl, b bowl, R bowl) where inner and outer borders differ,
   the centerline resembles the inner shape, scaled outward into the
   middle of the band. Visual check: place the centerline alongside
   the counter — same shape, larger size, sitting halfway out into
   the band.

3. STROKE TYPE PURITY
   Every geometric stroke is exactly one type — straight or curved —
   never mixed within a single stroke. Pedagogical merging of multiple
   geometric strokes into one tracing motion happens in the iPad
   anchor GUI, not in the bake.

4. JUNCTION CONTINUITY
   Where two geometric strokes meet, they share an exact endpoint
   pixel AND their tangents align. No direction discontinuity at the
   meeting point.

These apply to every letter, every weight, every bake. A bake that
violates any of them is not shippable, regardless of gate metrics.


## SKELETT bootstrap is read-only against editableStrokes

Opening a letter in SKELETT mode and saving without making any
handle edit produces a byte-identical strokes.json (modulo the
3-decimal rounding in CalibrationStore.persist). bootstrapHandles
derives the handles array from editableStrokes but never writes
back. editableStrokes is only mutated by user gesture handlers
(drag, insert, delete, anchor edits) and by the load/reset paths.

Verified by code audit of all 12 editableStrokes write sites in
StrokeCalibrationOverlay.swift and by Python simulator of the
bootstrap → handles → no-edit-save path against all 59 letters
(all show 0.00 px drift on the no-edit path).

The 40 px post-edit drift on D's bowl is a separate concern —
see SKELETT post-edit edit-locality issue.
