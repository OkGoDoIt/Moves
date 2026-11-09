# Moves — Agent Instructions

This file is shared by Cursor and Claude Code (`CLAUDE.md` is a symlink to it). Read it before changing anything.

Product direction, workstreams, and per-agent task briefs live in **`PLAN.md`**. Pick a workstream there before starting feature work.

Upstream review, selected adaptations, and pending Mac/multi-device integration decisions live in **`UPSTREAM.md`**. A reviewed upstream tip is not necessarily integrated. Preserve the fork’s schema and safety fixes when bringing in upstream work.

## What this repo is

Moves is a **private on-device timeline app** (SwiftUI + SwiftData). It records visits and movement, infers transport mode, and optionally uploads new points to Dawarich, Reitti, GeoPulse, OwnTracks Recorder, or Traccar.

This clone is Roger’s fork of [holgerkrupp/Moves](https://github.com/holgerkrupp/Moves). Signing identity is **not** in tracked files: `Config/Moves.local.xcconfig` (gitignored) sets team `R73F7TNT65` and prefix `com.okgodoit`, while the tracked `Config/Moves.xcconfig` keeps upstream’s `de.holgerkrupp` / `46D3VYP253` defaults. Changes are therefore upstream-safe by construction — **never hardcode a bundle ID, App Group, iCloud container, or team ID anywhere else**.

## Tooling

| Need | Use |
|---|---|
| Xcode | 27.x (this machine: 27.1 / iOS 27.1 SDK). Deployment target is **iOS 26** / watchOS 26. |
| Project | `Moves.xcodeproj`, scheme **Moves** (embeds Widgets + Watch). |
| Simulator default | iPhone 18 Pro, iOS 27.0 (`159ACCC1-78B1-4E1A-9BDE-F1315C3FE5B2`) |
| Physical iPhone | **G17**, iPhone 17, iOS 27.0, UDID `00008150-000534E2368A401C`. Developer Mode is on. |
| Not usable | **SlatePad** (iPad Air 5, iOS 18.7) is below the iOS 26 deployment target. |

SPM package: `CloudDataPresence` from `https://github.com/holgerkrupp/CloudDataPresence` (branch `main`). Xcode resolves it on first build.

`Scripts/generate-icon-previews.sh` is an **always-run** build phase. It refreshes icon picker previews from `Moves/Icons/*.icon` via private CoreUI. If a future Xcode breaks it, export PNGs from Icon Composer into `Moves/Assets.xcassets/iconPreviews` by hand.

## Identity and signing (read this before changing identifiers)

`Config/Moves.xcconfig` is the **single source of truth**. Everything derives from one setting:

```
MOVES_BUNDLE_ID_PREFIX = de.holgerkrupp   # tracked default (upstream)
MOVES_APP_BUNDLE_ID       = $(MOVES_BUNDLE_ID_PREFIX).Moves
MOVES_APP_GROUP_ID        = group.$(MOVES_APP_BUNDLE_ID)
MOVES_ICLOUD_CONTAINER_ID = iCloud.$(MOVES_APP_BUNDLE_ID)
```

It ends with `#include? "Moves.local.xcconfig"`, a gitignored per-developer override (template: `Moves.local.xcconfig.example`). It is wired as the **project-level** base configuration for Debug and Release, so `DEVELOPMENT_TEAM` and `PRODUCT_BUNDLE_IDENTIFIER` no longer appear in `project.pbxproj`.

How each layer reads it:

| Layer | Mechanism |
|---|---|
| Targets | `PRODUCT_BUNDLE_IDENTIFIER = $(MOVES_APP_BUNDLE_ID)` plus a `.widgets` / `.watchkitapp` / `.watchkitapp.widgets` suffix |
| Entitlements | `$(MOVES_APP_GROUP_ID)`, `$(MOVES_ICLOUD_CONTAINER_ID)`, `$(TeamIdentifierPrefix)$(MOVES_APP_BUNDLE_ID)` |
| Info.plist values | `$(PRODUCT_BUNDLE_IDENTIFIER)` for BGTask IDs and `CFBundleURLName`; `MovesAppGroupIdentifier` / `MovesCloudKitContainerIdentifier` keys expose them to Swift |
| Swift | `MovesAppIdentity` (compiled into app, widgets, watch app, watch widgets) reads those Info.plist keys; `MovesAppIdentity.bundleIdentifier` covers log subsystems and BGTask IDs |

Xcode expands `$(SETTING)` in plist and entitlement **values but not dictionary keys**, and `NSUbiquitousContainers` is keyed by the container ID. That one case goes through `INFOPLIST_PREPROCESS = YES` with the macro `MOVES_ICLOUD_CONTAINER_KEY`. Two traps if you touch this:

- `INFOPLIST_OTHER_PREPROCESSOR_FLAGS = -traditional` stops `cpp` from treating the `//` in the plist DOCTYPE as a comment.
- Never name the macro after a build setting the plist also references. `cpp` runs **before** build-setting expansion, so a macro named `MOVES_ICLOUD_CONTAINER_ID` also rewrites the text inside `$(MOVES_ICLOUD_CONTAINER_ID)`, and Xcode then expands a setting that does not exist — silently yielding an empty string.

After changing any of this, check the built plists rather than trusting the build to fail:

```sh
plutil -p ~/Library/Developer/Xcode/DerivedData/Moves-iphone/Build/Products/Debug-iphoneos/Moves.app/Info.plist \
  | rg "Moves(AppGroup|CloudKit)|NSUbiquitousContainers|BGTask" -A2
```

To build under a different account: `cp Config/Moves.local.xcconfig.example Config/Moves.local.xcconfig`, set the prefix and team, then build to a device once with an Apple ID in **Xcode → Settings → Accounts**. Automatic signing registers the App ID, App Group, and iCloud container. First device run may prompt **Trust This Developer**.

Without the iCloud entitlement, Core Data aborts the process (`SIGTRAP` on `com.apple.coredata.cloudkit.queue`) instead of throwing. `MovesApp.allowsCloudKitContainer()` therefore inspects `embedded.mobileprovision` first and falls back to a local-only store. It **fails open** when no profile is embedded, because App Store builds have none and are signed from the project entitlements.

## Build / test / run

From the repo root. Prefer XcodeBuildMCP when it is available (session defaults live in `~/.xcodebuildmcp/config.yaml` and `.xcodebuildmcp/config.yaml`).

**Simulator tests** (unit tests in `MovesTests`; last verified: all passing on iPhone 18 Pro / iOS 27):

```sh
xcodebuild test -project Moves.xcodeproj -scheme Moves \
  -destination 'platform=iOS Simulator,id=159ACCC1-78B1-4E1A-9BDE-F1315C3FE5B2'
```

**Simulator run:** scheme `Moves` → iPhone 18 Pro. Simulator uses an **in-memory** store and seeds demo days (`SimulatorDemoDataSeeder`). Allow Location / Motion when prompted; demo data is already visible.

**Device run:** unlock G17 first (`devicectl` cannot launch while the device is locked), then:

```sh
./Scripts/install-iphone.sh
```

Optional: `DEVICE_UDID=... ./Scripts/install-iphone.sh`.

## Layout (where to edit)

| Area | Files |
|---|---|
| Bundle IDs, App Group, iCloud container, team | `Config/Moves.xcconfig`, `Moves/MovesAppIdentity.swift` |
| App entry, SwiftData / CloudKit container | `Moves/MovesApp.swift` |
| Timeline UI, maps, day paging | `Moves/ContentView.swift`, `Moves/MovesRootView.swift`, `Moves/TimelineTabView.swift`, `Moves/MovesTimelineViews.swift`, `Moves/MovesJumpToDateView.swift`, `Moves/MovesDetailViews.swift` |
| Map tab | `Moves/MapTab/` (`MapTabView`, range pill/sheet/scrubber, layer chips, `MapWindowLoader`, `VisitedCellStore`); `ShareMapAggregate.swift` per-day buckets |
| Places tab | `Moves/PlacesTab/` (`PlacesTabView`, `PlaceDetailView`, `OccupancyChartView`, `PlacesIndex`); geocode backfill is `Moves/PlaceGeocodeBackfill.swift` |
| Insights tab & search | `Moves/InsightsTab/` (`InsightsTabView`, `InsightsSnapshot`, Connections); `Moves/MovesSearchView.swift`, `Moves/SearchQueryParser.swift`. Visit/journey aggregates remain in `Moves/MovesStatisticsSearchView.swift`. |
| Named trips | `Moves/Trips/` (`TripListView`, `TripDetailView`, `SaveTripSheet`, `TripRangeStats`); `NamedTrip` in `VisitedLocation.swift`. Insights has a Trips row; Map range pill menu → Save as trip; `moves://trip/{uuid}` / `moves://trips`. |
| Corrections, Review inbox, undo pill | `Moves/TimelineItemActions.swift`, `Moves/TimelineEditController.swift`, `Moves/PlaceRenameSheet.swift`, `Moves/EditTimesSheet.swift`, `Moves/SplitSheet.swift`, `Moves/ReviewInboxView.swift`, `Moves/UndoToast.swift`, `Moves/NearbyPlaceSuggester.swift` |
| Route matching / path policy | `Moves/RoadRouteMatcher.swift` (`RoadRouteMatcher`, `RouteMatchPlausibility`, `DirectionsProvider`); Path control in `MovesDetailViews.swift`; Settings → Map Appearance Path level |
| Models + repository | `Moves/VisitedLocation.swift` (`DayTimeline`, `VisitPlace`, `MoveSegment`, `LocationSample`, `KnownPlace`, `PhotoAttachment`, `PlaceCorrectionEvent`, `VisitedCell`, `NamedTrip`) |
| Place learning | `Moves/PlaceLearningEngine.swift` (resolve / learn / negatives / merge / clampRadius); hooked from `DefaultTimelineAssembler.ingestVisit` and `SwiftDataTimelineRepository`. Places tab occupancy, merge, and shrink consume these APIs. |
| Photos | `Moves/Photos/` (`PhotoLibraryService`, `PhotoHistoryImporter`, `PhotoAttachmentQuery`, storyline + range thumbnail strips, Settings → Photos). Read-only PhotoKit; Limited Library explained in Settings. Never modifies the library. Named trips (WS9b) lens `PhotoAttachment` rows in a date range — they do not copy photos. |
| Timeline lookup / schema upgrade | `Moves/TimelineLocator.swift`, `Moves/TimelineSchemaUpgrader.swift` |
| Route rendering / speed shading | `Moves/RouteRendering.swift`, `Moves/SpeedProfileBuilder.swift` |
| Settings, export, integrations | `Moves/MovesSettingsView.swift`, `Moves/DawarichSync.swift`, `Moves/WebhookSync.swift` (generic webhook), `Moves/MovesZipArchive.swift` (zip export/import) |
| iCloud status, privacy zones | `Moves/CloudDataPresencePublisher.swift` (Settings → iCloud), `Moves/PrivacyZones.swift` (Home/Work circles on share cards and exports) |
| Imports | `Moves/Import/` (Google Timeline: `GoogleTimelineImporter`, `GoogleTimelineDocument`, streaming `Records.json` scanner, zip reader); `Moves/OnboardingFlow.swift`; `Moves/TimelineArchiveImport.swift` (Moves GPX+GeoJSON+CSV+zip); `Moves/LocationLogImport.swift` + `Moves/RouteFileImport.swift` (any timestamped GPX/TCX/KML log → stays, moves, speed-based modes, geocoded names; bulk writer is `importLocationLog` in `VisitedLocation.swift`). Real-file fixtures live in gitignored `import-staging/` and `MovesTests/Fixtures/`; Google Timeline unit fixtures are `MovesTests/Fixtures/GoogleTimeline/`. |
| Location capture, motion, route tracking | `Moves/LocationChange.swift` (`MovesLocationCaptureManager`) |
| Stops and trips from stored fixes | `Moves/SampleStayInference.swift`; `reconcileSampleStays` in `VisitedLocation.swift`, driven by `DefaultTimelineAssembler`. It rebuilds the last week on every location batch, so it must leave corrected, imported, and reviewed items alone, and `RemovedTimelineSpan` records what the person removed so fixes don't bring it back. |
| Timeline assembly / transport inference | `DefaultTimelineAssembler` in the location/timeline sources; tests in `MovesTests/TimelineAssemblerTests.swift` |
| App Intents / Siri / Action button | `Moves/MovesAppIntents.swift` |
| Widgets + Live Activity | `Moves Widgets/` (route Canvas from `TimelineWidgetSnapshot.routePoints`; Live Activity uses the mode palette) |
| Watch companion GPS | `Moves Watch App/` (today’s route uses mode color assets); `Moves/WatchRouteTransferQueue.swift` serializes durable transfers |
| Adaptive / iPhone Duo layouts | `ContentView.swift` (`LandscapeSplitView`, `MovesDetailArrangement`), `MovesDetailViews.swift`, `MovesTimelineViews.swift`; design and verification in `duo.md` |
| Optional calendar sync | `Moves/CalendarSync.swift`; Settings → Calendar. Dedicated Moves calendar, names and times only, explicit account/start-date selection, off by default. |

Keep capture, Live Activity, uploads, and SwiftData writes **independent of view identity**. Fold/open/rotation must not tear down `MovesLocationCaptureManager`.

## Visual quality

Polish is a release requirement, including on normal iPhones. Inspect rendered
screens, not only accessibility labels or passing tests. Check small, standard,
and large phone sizes, portrait and landscape, larger text, keyboard-visible
forms, long names, empty states, and populated history. Exercise the main tabs,
details, corrections/Undo, search, and changed settings/import flows. Keep labels
readable, touch targets usable, disclosure arrows singular, and maps visible
beside their controls. Save before/after evidence using synthetic data; keep real
phone screenshots private. Report exactly what was inspected and what remains.
Further iPhone Duo work is low priority; Roger's everyday iPhone experience takes
precedence. See `docs/VISUAL-QA.md` for the current coverage record.

## Product constraints

- Timeline data stays on-device; CloudKit is the user’s **private** container, not a public database.
- Automatic integration uploads send **new** points only; backfilling local history needs an explicit per-destination confirm.
- Export (GPX / GeoJSON / CSV) and App Intent export require user action; export via Siri/Shortcuts requires device authentication.
- Spotlight `IndexedEntityQuery` donates place name + visit time only — never coordinates or comments.
- Background modes: visit monitoring + significant location changes; temporary high-accuracy route tracking is opt-in and shows a Live Activity.

## Store safety

Never hold a model across a delete on another context: touching a row another context deleted aborts the process (`SwiftData/BackingData.swift: This model instance was invalidated`), and nothing can catch it. Long background reads copy values out of a prefetched fetch (see `ShareMapAggregateBuilder`). Use `MovesApp.sharedContainer()`; a second container means a second CloudKit mirror on one file. Anything that deletes rows in bulk at launch goes in `TimelineSchemaUpgrader`, which holds back the timeline UI and background work until it finishes.

To check a change against real history before it reaches a phone, back up the device (`xcrun devicectl device copy from --domain-type appGroupDataContainer --domain-identifier group.<bundle id> --source / --destination import-staging/device-backup-<date>/group-container`, which is gitignored). `StoreResilienceTests` then runs against that copy. Launching the simulator with `SIMCTL_CHILD_MOVES_SIMULATOR_STORE=<path to a copy of default.store>` opens that copy instead of demo data.

## Git hygiene

The upstream tree committed `build/`, `.DS_Store`, and `xcuserdata/`. This fork has a `.gitignore` for those; do not add more DerivedData or `*.xcuserstate`. Do not `git rm --cached` the historical `build/` tree unless the user asks for a cleanup commit.

`Config/Moves.local.xcconfig` is gitignored and holds this machine’s team ID and bundle prefix. Never commit it, and never move its values into a tracked file.


## Upstream integration maintenance

Read `UPSTREAM.md` before pulling upstream again. Reviewed tip is not merged ancestry.
The local `DurableImportQueue` owns route/Google/archive imports; interrupted work resumes
explicitly and must preserve corrections and removal tombstones. `DetailedExploration`
uses original ground observations plus separately stored undated Fog coverage. Coverage
exports obey privacy zones. `Packages/RouteFileKit` and `Packages/FogOfWorldKit` are
vendored upstream source, with fork adaptations recorded in `UPSTREAM.md`; Quick Look
extensions have no timeline-store or capture access. Native Mac/multiple-device work is
deferred. The process-owned `MovesRuntime` must outlive view rotation/navigation.
