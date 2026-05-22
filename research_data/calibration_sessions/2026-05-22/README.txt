Primae calibration session logs
================================

Every time you save a SKELETT or ANKER edit in the calibrator,
a JSON file lands here as `<letter>/<timestamp>.json` capturing
the polyline before and after your edit plus a few metadata
fields. These pairs are the training-data corpus for future
correction-pattern analysis.

Safe to delete this entire folder; the app re-creates it on
next launch. Safe to leave it growing; each save is small
(~5-30 KB).