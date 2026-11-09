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

Broader ordinary-phone review is in progress. Do not read this document as a claim
that every screen, device size, or accessibility setting has passed.
