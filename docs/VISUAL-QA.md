# Visual quality review

Polish is part of completing a feature. Automated behavior tests and rendered UI
inspection answer different questions; neither substitutes for the other.

## Review coverage

Use synthetic demo history on small, standard, and large iPhones. Check portrait,
landscape, normal and enlarged text, and both light and dark appearances where
colors are changed. Verify iPad compatibility when shared sizing changes. Mac is
a separately deferred product, and Duo is currently low priority.

Check these flows with real taps, scrolling, typing, and submission:

- Timeline: day navigation, selection, short stops, mode menu, Undo, and review.
- Details: place names and notes, path choices, route editing, and keyboard access.
- Map: range picker, layers, scrubber, and trip creation.
- Places: search, long names, confirmation, details, and occupancy.
- Insights: units, charts, year selection, connections, and trips.
- Settings: permissions, calendar setup, import progress/errors, and exports.

Inspect the resulting screenshot at readable scale. Names must not collapse into
letter columns; controls must not compete for the same space; each navigation
action needs one disclosure indicator; forms must remain usable with the keyboard
open; scrollable content must reach clear of the tab bar. Do not invent new visual
motifs to fix sizing problems. Match the existing typography, colors, cards, and
spacing.

## November 9 record

Build 44 is installed on G17 and is the walking-test baseline. Its portrait
timeline was inspected on the physical phone before and after updating. Current
capture was observed. Device screenshots remain in private staging.

The Duo review exposed cramped row allocation and oversized detail overlays.
Timeline allocation, intact mode labels, duplicate arrows, and locale speed units
were corrected. The timeline was visually inspected wide and in tabletop pose,
and selection survived folding/rotation. The final bounded detail card and
short-display map sizing compiled, but were not visually signed off on Duo before
the user prioritized the G17 installation.

### Ordinary iPhone follow-up

The dedicated iPhone 17e simulator uses synthetic demo history. Inspected:

| Flow | Observed result |
|---|---|
| Portrait timeline | Place names, two-line journey names, mode labels, and one disclosure arrow remain readable. |
| Landscape timeline | Removing the repeated section heading makes more space for journeys. Touch scrolling reaches the final visit and returns to the first. |
| Map and range selection | Landscape map controls stay separate; choosing This week updates the range. |
| Places search | Typing Bondi filters correctly with the software keyboard visible; tapping the result opens its detail page. |
| Place detail | Map, visit totals, and occupancy chart render coherently in portrait. |
| Journey note | Entering and saving a note worked; rotating preserved the draft. Added bottom scroll-content margin; a touch drag was observed bringing the note and Save above the tab bar. The full editor remains scrollable instead of reducing its viewport. |

Evidence is under `docs/qa/2026-11-09/`: `phone-portrait-timeline.png`,
`phone-landscape-timeline-after.png`, `phone-search-keyboard.png`, and
`phone-landscape-detail-before.png`.

The Mac locked before a final detail screenshot could be saved; the unobstructed note and Save state was observed in the tool screenshot.

This is a recorded pass over representative flows, not an exhaustive sign-off.
The remaining matrix includes the shortest supported iPhone, large iPhones,
maximum accessibility text, dark appearance, secondary sheets, and the final
combined upstream feature build. Duo remains lower priority. Each new or changed
surface must receive its own rendered interaction check before it is called done.

The final compact-layout source (`0b4ae17e`) passed its full suite: 392 tests,
zero failures, and zero runtime warnings. Fifteen checks were skipped because the
isolated worktree lacks optional private import fixtures and calendar permission;
the copied-phone store-preservation test passed. Result bundle:
`/tmp/Moves-phone-polish-final-tests.xcresult`. The broader integration chat owns
the combined merge and pre-push suite. These post-walk polish changes are not yet
installed on G17; build 44 remains the verified phone baseline.

## November 25 record: Settings → Photos and the photo-history import

Inspected on iPhone 18 Pro Max (iOS 27.0) with 4,000 synthetic geotagged photos
loaded into the simulator library:

| Flow | Observed result |
|---|---|
| Photos card, idle | Both toggles, the "photos used this week" line, and the history row render without clipping. |
| Import sheet, setup | Date pickers, the saved-photos toggle, and counts; the count line names how many saved or imported photos are left out. |
| Import running | Bar, "Importing now", "Imported back through …", and photos checked update per step. 4,005 photos finished in about 12 seconds; build 46 was at 58% after 150 seconds on the same library. |
| Import finished | Card and sheet both show when it finished, how far back it reached, and what it added; survives relaunch. |
| Paused, then Resume | Planted paused job shows a grey bar and "Paused"; Resume runs it to the end. |
| Relaunch mid-import | Planted running job with a cursor in 2023 resumed on launch and imported only photos before the cursor (checked in the store). |
| New photos | Photos added while the app was open were classed as camera photos and counted on the status line; one placed in another country from the demo fixes was refused. |
| Dark appearance, largest text | Card and sheet stay legible; nothing overlaps. |

Not inspected: a small phone (iPhone 17e), landscape, and the final copy of the
status line ("used" in place of "added") and stacked paused buttons, which were
changed after the last screenshots; the simulators were needed elsewhere. The
time-remaining text needs more than two steps to appear and was not seen with
4,000 photos. Evidence is under `docs/qa/2026-11-25/`.
