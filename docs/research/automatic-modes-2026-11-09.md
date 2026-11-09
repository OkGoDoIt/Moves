# Automatic modes and noisy recording evidence

Workstream: PLAN.md WS2, Corrections & Review. Roger selected **A, all mode
switches together**, on November 9 after comparing the interactive designs in
`docs/design/automatic-modes/index.html`. Use the existing SettingsCard, mode
colors, and rounded typography. Native geometry retains 14-point card corners,
12-point card padding, 14-point card spacing, 49-point minimum mode rows,
11-point mode dots, and a 16-point label that scales with Dynamic Type.

## Requested behavior

Settings → Travel modes → Automatic modes has switches for walking, running,
cycling, automotive, train, plane, boat, and swimming. All start enabled;
preferences affect guesses, not the correction menu. Changing a switch does not
rewrite history. **Recheck past trips** acts only on eligible guesses for modes
currently disabled. Unknown is the result when the remaining evidence cannot
support another mode. Cleanup preserves curated and explicitly imported modes,
points, visits, dates, distances, and comments. A local undo record survives
reopening the app; Undo does not overwrite later corrections or recreate deleted
trips. No bulk history changes have been applied to Roger's phone.

## Evidence inspected

Read-only analysis of the November 9 device backup copied into the gitignored
`import-staging/device-backup-2026-11-09-mode-analysis/` directory: **572 moves,
774 visits, and 7,415 points**. The backup and per-trip analysis remain private.
`Scripts/analyze-transport-evidence.py` reproduces aggregate quality counts
without printing coordinates, names, comments, or trip identifiers.

There are **45 cycling labels overall**, and **26 since September 9**. Roger
explicitly said every cycling label in the last couple of months is wrong. This
establishes negative cycling examples; it does **not** establish whether each
trip was a walk, taxi, motorbike, or something else.

Across the 45 cycling-labeled trips:

- 21 have a gap longer than five minutes.
- 10 have an apparent speed above 9 m/s between fixes less than five seconds apart.
- 12 have an interval above the old cycling threshold that does not rule out
  walking after subtracting both fixes' recorded accuracy radii.
- Four have fewer than three points, and 27 have no positive recorded step count.
- 26 include points from a file import.

These are overlapping warning flags in the raw records, not proof of what caused
each historical classification. The prior live assembler already filtered some
fixes; historical Core Motion readings and complete decision provenance are not
stored. Imported points commonly have the parser's default 15-meter accuracy,
which must not be mistaken for a measured uncertainty. There is no stored
low-power-state flag or speed-accuracy field, so this dataset cannot establish a
causal effect of Low Power Mode or recover calibrated speed uncertainty.

## Problems in the previous rules

The speed fallback selected running, cycling, and train from non-overlapping
speed buckets even though real modes overlap. One reported speed of 80 m/s could
upgrade a trip to flying. A road-speed average and distance could become train.
The step rule could label a fast walk with few steps as cycling; a long bicycle
ride could become automotive from distance and speed alone. A lone low-confidence
motion state could get the same high dominance score as strong, complete evidence.
The raw-log classifier weighted by distance, allowing a GPS jump to have an
outsized vote. Cleanup must not replay those assumptions on old guesses.

## Implemented inference policy

`TransportSpeedEvidence` is shared by live speed fallback, unlabeled log imports,
and explicit history cleanup. It screens invalid and very inaccurate fixes,
groups near-simultaneous readings, and removes isolated short excursions when
neighboring fixes contradict them. None of this deletes stored points.

Dense fixes accumulate into independent 30–60 second or longer baselines so
walking displacement can rise above positional uncertainty. Each interval has a
speed range based on both endpoint accuracy radii. Intervals over five minutes
are missing evidence, not confident continuous travel. Ordinary speed inference
requires at least two intervals, a minute observed, and coverage of at least half
the span. Duration-weighted medians prevent a short spike dominating the vote.
Consistent reported speeds support inference; a single exceptional speed does not.

Speed alone can support a clear walk, ordinary vehicle speed, or strong
long-distance flight evidence. Overlapping running, cycling, and train speeds
remain Unknown without another source. Motion can still identify walking,
running, cycling, or automotive when enabled. Motion confidence now accounts for
coverage and the sensor's confidence, not dominance alone. Speed-only confidence
is capped below the Review threshold; it is a heuristic score, not a calibrated
probability.

A walking/running correction needs repeated, uncertainty-adjusted incompatible
speed over at least half the trip, in addition to the existing step checks.
Missing steps alone do not identify a vehicle. Length alone no longer overrides
cycling motion. Explicit archive/workout modes remain their source's labels.
New automatic photo-flight guesses also respect the enabled-mode settings.

## Limits of this evaluation

This is a conservative reduction in unsupported labels, not a measured global
accuracy improvement. Roger supplied negative cycling ground truth but no
complete, independently labeled walking/driving/cycling test set. More Unknown
results are an intentional cost; replacement labels are still guesses and remain
reviewable. Recorded accuracy radii are estimates, not guaranteed bounds. A
consistent GPS offset, mixed-mode journey, wrong visit boundary, or confidently
wrong motion reading can still be ambiguous or incorrect. No automated history
rewrite accompanies installation.

## Verification

Initial settings/cleanup implementation: 411 tests passed, four skipped.
First inference-focused run: 71 passed, no skips or failures. Final serial run:
**415 passed, four skipped, zero failures**, 419 total, on iPhone 17e / iOS 27.0.
The four skips are three opt-in Google Takeout checks and one Calendar permission
integration test. The result bundle reports no runtime warnings. Existing build
warnings remain. Parallel simulator launch retries were encountered; the final
verified run used one destination serially. Local result bundle:
`/tmp/Moves-mode-verified-tests.xcresult`.

On a copy of the real store, cleanup reclassified all 45 eligible cycling guesses:
four walking, three automotive, and 38 Unknown. For the 26 since September 9
identified by Roger as false cycling, two became walking and 24 Unknown. These
replacement labels are unverified guesses. Undo restored all 45 original labels
and review states; all 572 moves, 774 visits, and 7,415 points remained. Tests also
cover durable undo, later edits/deletions, protected imported/reviewed/manual
records, and failure to write the recovery file.

The initial native screen was rendered on an iPhone 17e with synthetic history.
Toggling cycling updated the eligible count, and the cleanup action produced a
result and exposed Undo. Remaining final UI checks are pending.

## API references

- [Apple: CLLocation speed](https://developer.apple.com/documentation/corelocation/cllocation/speed):
  an instantaneous measurement; negative is invalid, and speeds can change
  between delivered events.
- [Apple: CMMotionActivity](https://developer.apple.com/documentation/coremotion/cmmotionactivity):
  motion flags are not mutually exclusive; confidence accompanies the state.

The statistical screening above is this fork's policy, not an accuracy guarantee
made by Apple.
