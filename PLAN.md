# Moves — Product & Implementation Plan

Status: **agreed direction, not yet started** (2026‑09‑20).
Owner: Roger. This document is the shared brief for every agent working on the fork. Read `AGENTS.md` first (tooling, signing, layout), then this file. Each workstream below is written so that one agent can own it end‑to‑end with minimal coordination; the **Foundations** workstream must land before the others start in parallel.

---

## 1. Vision

A private, lifelong location diary that the user fully owns. It runs quietly in the background on a low‑power budget, shows *where you went, how you got there, and how long you stayed*, lets you look up any moment of any day, and lets you take your data anywhere. It should feel like the original **Moves** (storyline, learned places, one‑tap export) rebuilt with the polish of **Arc Timeline** and the analytics of **Dawarich**, without a subscription, a server, or a third party.

### Principles (in priority order)

1. **Honest data.** Never present an inference as a recording. Recorded, snapped, estimated, manual, imported, and photo‑inferred all look different and say what they are.
2. **Correct in one or two taps.** Every mistake the engine can make has a direct fix on the row where it appears, with visible Undo.
3. **Learn from corrections, but don't overreach.** Confirmed corrections teach the app; guesses never teach it. When two learned answers compete, ask instead of guessing.
4. **Today first.** The default view is today's story; any other range is two taps away.
5. **Low power by default.** Visit monitoring + significant location changes remain the default capture. Dense GPS stays an explicit, time‑boxed session. Smarter processing compensates for sparse data; we do not spend battery to avoid writing algorithms.
6. **Less is more.** Four tabs, one search, no settings sprawl. If a control needs a paragraph to explain, redesign it.

### Decisions already made

| Question | Decision |
|---|---|
| Home screen shape | **Storyline‑first** (Arc / original Moves lineage). Tabs: Timeline · Map · Places · Insights. |
| Photos library | **Full**: read access, inline thumbnails on visits, and an EXIF‑based history backfill importer. |
| First milestone | **Shell + Timeline tab** (tab bar, tall mode‑colored map, storyline redesign, corrections, time‑of‑day lookup). |
| Recording default | **Keep low‑power default**; rely on smarter snapping/inference. Route‑tracking sessions stay opt‑in. |
| Ambiguous nearby places | **Auto‑assign once the ranking is clearly ahead** (top − second ≥ 0.25). Always show an "auto" mark so the user can still flip it. Chooser while the margin is below that. |
| Timeline speed shading | **Follow the Map setting.** Collapsed Timeline header stays solid mode color; expanded Timeline hero uses speed shading iff Map has it on. |
| Fog layer | **Adaptive**: store street‑level (~100 m) cells; draw neighborhood (~250 m) when zoomed out and street‑level when zoomed in. |
| Named trips | **M3 with Photos**: date range + notes + photos from visits in range; trip list; "Save this range as a trip" from Map. |
| Webhook payload | **Both**: OwnTracks‑compatible points for existing tools, plus a Moves‑native visits/moves JSON. |
| Arc import | **Skip** until someone contributes a sample export. Google Timeline + photos + GPX/Health cover history backfill. |

---

## 2. Landscape (what we are measuring against)

- **Arc Timeline 4** — Timeline / Places / Activity / Search tabs. Storyline with inline photo thumbnails; per‑item detail with duration, distance, speed, steps, floors, HR. Places grouped by country → city with visit counts and occupancy charts. Learned place footprints fed **only by confirmed visits** ("Drift Profiles"). Corrections train the classifier. Health import, calendar sync, JSON/GPX export. Subscription; reliability complaints. *Our UI benchmark.*
- **Dawarich** (web + thin iOS app) — Map / Insights / Settings. Map with scrubbable day strip, **Replay**, heatmap / points / lines / **fog of war** layers, privacy zones, named **Trips** (date range + notes + photos), public share links. Insights: yearly totals with deltas, countries/cities, activity calendar, streaks, monthly distance, time‑of‑day patterns, digests. Google Takeout import, 183‑day residency counter. *Our analytics benchmark.*
- **Google Maps Timeline** — on‑device since Dec 2024, 3/18/36‑month auto‑delete, Places / Cities / World tabs, monthly recap notification. Users miss "when did I last visit this place?" and any lifelong view. *The thing people switch from; we must import its JSON.*
- **Original Moves (ProtoGeo, †2018)** — Storyline, learned Places, activity **bubbles** sized by time, one‑tap zip export (csv/geojson/gpx/kml/ical/json).
- **Fog of World** — exploration as the product; track editing to fix drift. **Gyroscope Places** — country/city "passport", visit splitting, 20+ travel types. **Timeline Recovery / Pino / FollowPhoto / Photo Geotag** — prove that clustering photo EXIF into visits is viable and wanted.

---

## 3. Current state (HEAD `00fdc56`)

The engine is ahead of the UI. Detailed inventory lives in the session transcript; the short version:

**Have:** day pager (`ContentView` → `TabView` of `DayTimelinePage`), collapsed 180pt map strip (`DayMapStrip`), storyline (`StorylineRow`), place/move detail with rename, comment, mode change, drag‑to‑edit route (`PlaceMapDetailView`, `MoveMapDetailView`), MKDirections snapping with plausibility checks (`RoadRouteMatcher`, `RouteMatchPlausibility`), Health workout routes, five server integrations (`DawarichSync.swift`), share‑card generator with heat map and per‑period aggregates (`MovesShareViews.swift`, `ShareMapAggregate.swift`), nightly iCloud Drive backup, GPX/GeoJSON/CSV export, imports (Moves archive, Health, GPX/TCX/KML/GeoJSON files), Watch GPS, Live Activity, Siri/Shortcuts, Spotlight, widgets.

**Missing / weak (UX):** single screen with everything behind three toolbar icons; no Places, Map, or Insights destinations; map strip is small and collapses walk/run/bike/car into one color (`RenderedRoute.tint`); statistics are all‑time only (`MovesStatisticsSnapshot`); no time‑of‑day lookup (`MovesJumpToDateView` is day‑grain); no onboarding; no merge/split/time edit; no photos; no Google/Arc import; CloudKit invisible; widgets have route points but draw no map.

**In flight (do not touch):** `Moves/LocationLogImport.swift`, `MovesTests/LocationLogImportTests.swift`, and the related edits in `RouteFileImport.swift` / `VisitedLocation.swift` / `project.pbxproj` are being worked on separately. HEAD + that WIP does not compile yet (`RouteFileImport.swift:74`). Branch from `main` and rebase when it lands.

---

## 4. Information architecture

```
TabView (MovesTab)
├── Timeline   — today's story (home). Day header ▸ tall map ▸ storyline ▸ activity bubbles
│                toolbar: [Search] [Route tracking] · Review badge on tab
├── Map        — browsable map for any range. Range pill ▸ map ▸ scrubber ▸ layer/mode chips
├── Places     — learned places by country ▸ city. Detail: visits, time, occupancy, footprint
└── Insights   — per‑year totals, countries/cities, calendar, streaks, monthly distance, patterns

Settings       — sheet from a profile‑style button on Timeline and Insights (not a tab)
Search         — toolbar item on Timeline/Places; results: places, days, moments ("Tue 3pm")
Share          — contextual: from a day (Timeline), a range (Map), a place, or Insights year
```

Deep links (extend `ContentView.handleDeepLink`): `moves://today`, `moves://day/2026-09-20`, `moves://at/2026-09-20T15:32:00+07:00`, `moves://place/{uuid}`, `moves://map?from=…&to=…`, `moves://tracking`, `moves://review`.

Landscape phone keeps `LandscapeSplitView` (map beside list) inside the Timeline tab.

---

## 5. Design system additions

**Mode palette** (single source: `MovesPalette.transport(_:)`, extend to cover all modes; also used by share cards, summary bubbles, Watch, widgets):

| Mode | Color | Line |
|---|---|---|
| walking | green | 4pt |
| running | orange | 4pt |
| cycling | blue | 4pt |
| automotive | grey‑violet | 4pt |
| train | existing asset | 4.25pt |
| plane | existing asset | 4.5pt + faint great‑circle shadow |
| boat / swimming | existing assets | 4pt |
| unknown | neutral grey | 4pt |

**Route states** (visual grammar, applied everywhere a route is drawn):

| State | Meaning | Rendering |
|---|---|---|
| Recorded | dense fixes (route tracking, Health, Watch, file import) | solid, full opacity, raw fixes not shown |
| Snapped (high) | fixes matched to network within their accuracy corridor | solid; faint raw‑fix dots underneath |
| Snapped (medium) | sparse fixes, plausible directions route | solid at 75% opacity; raw‑fix dots |
| Estimated | endpoints only or rejected match | **dashed**, 60% opacity |
| Manual | user‑dragged | solid with subtle edit glyph at midpoint |
| Photo‑inferred | visit/move created from photo EXIF | dotted, with photo glyph on the visit |

**Speed shading** (option, default on for Map tab, off for the collapsed Timeline header): lightness along the line rises with speed relative to the mode's typical range (walking 0–7 km/h, running 6–20, cycling 5–40, automotive 0–130, train 0–300). Implemented as a `Gradient` stroke along the polyline (see WS4).

**Type & layout:** keep `.rounded` SF for numbers, system text elsewhere; 14pt horizontal safe padding; cards with 20pt radius as in `SettingsCard`. Respect Dynamic Type; every gesture action has a menu equivalent.

---

## 6. Data model changes (Foundations)

All changes must respect **SwiftData + CloudKit** constraints: every stored property has a default, relationships are optional, no `@Attribute(.unique)`. New enum cases store as `String` raw values so existing rows stay valid. Provide a lightweight migration pass (`TimelineSchemaUpgrader`) that runs once per version on launch and backfills derived fields in the background.

### 6.1 New `@Model` types

```swift
/// A real‑world place the user has confirmed at least once. Visits point at it.
@Model final class KnownPlace {
    var id: UUID = UUID()
    var name: String = ""
    var centerLatitude: Double = 0
    var centerLongitude: Double = 0
    /// Learned radius in meters; grows only from confirmed visits. 25…150.
    var footprintRadius: Double = 40
    var confirmedVisitCount: Int = 0
    var category: String? = nil            // "home", "work", "gym", free text
    var countryCode: String? = nil         // ISO 3166‑1 alpha‑2, from reverse geocode
    var locality: String? = nil            // city
    var administrativeArea: String? = nil
    /// Reverse‑geocoded names the user has explicitly rejected here.
    var rejectedAutoLabels: [String] = []
    /// 24‑bin histogram of confirmed arrival hours; 7‑bin weekday histogram; stay durations (s).
    var arrivalHourHistogram: [Int] = Array(repeating: 0, count: 24)
    var weekdayHistogram: [Int] = Array(repeating: 0, count: 7)
    var stayDurationSamples: [Double] = []   // keep last 50
    var createdAt: Date = Date.now
    var lastVisitAt: Date? = nil
    @Relationship(inverse: \VisitPlace.knownPlace) var visitsStorage: [VisitPlace]? = nil
}

/// A photo from the user's library associated with a visit (thumbnail shown inline).
@Model final class PhotoAttachment {
    var assetLocalIdentifier: String = ""
    var capturedAt: Date = Date.now
    var latitude: Double? = nil
    var longitude: Double? = nil
    var visitPlace: VisitPlace? = nil
    var dayTimeline: DayTimeline? = nil
    var createdAt: Date = Date.now
}

/// Immutable log of user corrections; the learning input. Never edited, only appended.
@Model final class PlaceCorrectionEvent {
    var id: UUID = UUID()
    var timestamp: Date = Date.now
    var visitPlaceID: UUID = UUID()
    var fromKnownPlaceID: UUID? = nil
    var fromAutoLabel: String? = nil
    var toKnownPlaceID: UUID? = nil
    var latitude: Double = 0
    var longitude: Double = 0
    var arrivalHour: Int = 0
    var weekday: Int = 0
    var stayDuration: Double = 0
}

/// Cache of visited 100 m grid cells for the fog / heat layers. Rebuilt incrementally.
@Model final class VisitedCell {
    var cellKey: String = ""      // "\(latIndex)|\(lonIndex)" at 0.001° resolution
    var firstVisitedAt: Date = Date.now
    var lastVisitedAt: Date = Date.now
    var sampleCount: Int = 0
}
```

### 6.2 Fields added to existing models

`VisitPlace`
- `knownPlace: KnownPlace?`
- `assignmentSourceRaw: String = "none"` → `PlaceAssignmentSource { none, user, auto, autoAmbiguous }`
- `assignmentConfidence: Double = 0` (0…1)
- `originRaw: String = "sensor"` → `TimelineItemOrigin { sensor, imported, photoInferred, manual }`
- `isHiddenAsShortStop: Bool = false` (currently computed in `DayTimelinePageContent.shouldHidePlaceFromTimeline`; persist so it can be user‑overridden)
- `countryCode`, `locality`, `administrativeArea` (`String?`, populated by `CLGeocoderPlaceNameResolver` and a backfill job; needed by Places/Insights)
- `reviewStateRaw: String = "none"` → `ReviewState { none, pending, confirmed, dismissed }`

`MoveSegment`
- `routeMatchPolicyRaw: String = "auto"` → `RouteMatchPolicy { auto, recorded, roads, manual }`
- `routeMatchConfidenceRaw: String = "unknown"` → `RouteMatchConfidence { recorded, high, medium, estimated, unknown }`
- `routeMatchSummary: String? = nil` (one‑line human explanation, e.g. "Matched to footpaths · 94% of fixes within 12 m")
- `transportModeSourceRaw: String = "auto"` → `TransportModeSource { auto, user, imported }`
- `originRaw: String = "sensor"` (same enum as above)
- `speedProfileData: Data? = nil` (encoded `[Float]` per rendered vertex, for speed shading; cache)
- `reviewStateRaw` as above

`LocationSampleSource` new cases: `.photoLibrary` (priority 1, not a route track), `.googleTimelineImport`, `.arcImport` (priority 7, `isRouteTrack` true when the source was a raw track, false for visit anchors — see WS11).

`DayTimeline`
- `photosStorage: [PhotoAttachment]?` (cascade)

### 6.3 Repository additions (`TimelineRepository` + `SwiftDataTimelineRepository`)

```swift
// Corrections
func dissolveVisit(_ visit: VisitPlace) throws -> MoveSegment      // "Not a stop": merge in+out moves
func mergeVisits(_ a: VisitPlace, _ b: VisitPlace) throws -> VisitPlace
func splitMove(_ move: MoveSegment, at date: Date) throws -> (MoveSegment, VisitPlace, MoveSegment)
func splitVisit(_ visit: VisitPlace, at date: Date) throws -> (VisitPlace, VisitPlace)
func updateTimes(of visit: VisitPlace, arrival: Date, departure: Date?) throws
func setTransportMode(_ mode: TransportMode, for move: MoveSegment, source: TransportModeSource) throws
func setRouteMatchPolicy(_ policy: RouteMatchPolicy, for move: MoveSegment) throws
// Places
func assign(_ visit: VisitPlace, to place: KnownPlace, source: PlaceAssignmentSource, confidence: Double) throws
func createKnownPlace(from visit: VisitPlace, name: String) throws -> KnownPlace
func knownPlaces(near coordinate: CLLocationCoordinate2D, within meters: CLLocationDistance) throws -> [KnownPlace]
func recordCorrection(_ event: PlaceCorrectionEvent) throws
// Lookup
func timelineItem(at date: Date) throws -> TimelineLocator.Result
func moves(in range: DateInterval, modes: Set<TransportMode>?) throws -> [MoveSegment]
func visits(in range: DateInterval) throws -> [VisitPlace]
```

All mutating calls register with `modelContext.undoManager` (already wired to `AppUndoController`) so the Undo pill and shake‑to‑undo cover them.

---

## 7. Workstreams

Each workstream lists: goal → user stories → UX spec → implementation tasks → acceptance → tests → files owned → dependencies. "Owns" means that agent is the only one editing those files during the milestone; shared files (`VisitedLocation.swift`, `MovesRouteSupport.swift`, `MovesPalette`) are edited only by **WS0** or by the owner named in the task.

### WS0 — Foundations (must land first, ~1 agent, small PRs)

Goal: the schema, enums, palette, and shell scaffolding every other workstream depends on. No visible UI change beyond the tab bar.

Tasks
1. Add the models/fields in §6 to `Moves/VisitedLocation.swift`. Register new models in `MovesApp.makeModelContainer()` schema (both CloudKit and local fallback paths).
2. `TimelineSchemaUpgrader` (new file `Moves/TimelineSchemaUpgrader.swift`): version key in `UserDefaults`; on first run after upgrade, in a detached task with its own `ModelContext`: (a) create `KnownPlace`s by clustering existing `VisitPlace.userLabel`s (same name within 120 m → one place; center = mean, radius = max(25, p90 distance)), assign those visits with `.user`; (b) copy the current short‑stop heuristic into `isHiddenAsShortStop`; (c) set `routeMatchPolicy = .manual` where `manualRouteCoordinatesData != nil`, `.recorded` where `usesHighAccuracyRouteTracking`; (d) leave `countryCode`/`locality` for the geocode backfill job (WS8).
3. Extend `MovesPalette.transport(_:)` to return distinct colors for walking/running/cycling/automotive/unknown; add `MovesPalette.speedShade(base:fraction:)`. Update `RenderedRoute.tint` to use it (keep Health pink and route‑tracking teal as *overlays* — see WS4 for the final rule).
4. Add `MovesTab` enum and a `MovesRootView` with `TabView` hosting `TimelineTabView` (wraps today's `ContentView` body), `MapTabView`, `PlacesTabView`, `InsightsTabView` placeholders. Move `ContentView`'s sheets/deep links into `MovesRootView`. Keep `MovesLocationCaptureManager` as an `@EnvironmentObject` above the `TabView` (capture must not depend on tab identity).
5. Add the `TimelineRepository` methods in §6.3 with straightforward implementations (no learning logic yet). Unit tests for `dissolveVisit`, `mergeVisits`, `splitMove`, `updateTimes` in `MovesTests/TimelineEditingTests.swift`.
6. `TimelineLocator` (new file): `locate(at:)` returns `.visit(VisitPlace)`, `.move(MoveSegment, coordinate: CLLocationCoordinate2D, progress: Double)` (interpolate along `RoadRouteMatcher.matchedCoordinates` by time), or `.gap(before:after:)`.

Acceptance: app builds, all 57 existing tests pass, tab bar shows four tabs, today's timeline works unchanged in the Timeline tab, upgrade runs once and is idempotent.

Owns: `VisitedLocation.swift` (models + repository), `MovesApp.swift`, new `MovesRootView.swift`, `TimelineSchemaUpgrader.swift`, `TimelineLocator.swift`, `MovesPalette` in `MovesRouteSupport.swift`.

---

### WS1 — Timeline tab redesign  *(Milestone 1)*

User stories
- "Open the app and see today's route on a big map with each leg colored by how I moved."
- "Read the day as a story: places with how long I stayed, legs with how far and how fast."
- "Swipe back a day; jump to any date; find where I was at 15:32 last Tuesday."

UX spec
- **Day header**: weekday + date (tap → Jump to Date & Time), chevrons, small "N places · N moves · X km" line. Today shows a live "now" dot.
- **Map hero**: 42% of the screen height in portrait (min 260pt), mode‑colored polylines with the route‑state grammar, place dots with the `KnownPlace` name for confirmed places. Tap a leg/dot → highlights the storyline row and shows a compact callout. Drag handle to expand to full screen (replaces the current 180pt strip + expand button). Speed shading follows the Map setting.
- **Storyline**: vertical rail. Place row: name, arrival–departure, stay duration, photo thumbnails strip (WS10), "auto" mark when `assignmentSource == .auto`, chooser chip when `.autoAmbiguous`. Move row: mode glyph in mode color, duration, distance, avg speed, steps if any, confidence glyph (dashed icon for `.estimated`). Hidden short stops collapse into a hairline "1 short stop hidden" row that expands.
- **Activity bubbles**: replace `DayTransportSummaryView` with a horizontal row of circles per mode, diameter scaled by moving time (min 44pt, max 88pt), label = duration, sublabel = distance. Tap → filters the map to that mode.
- **Jump to Date & Time**: extend `MovesJumpToDateView` with an optional time wheel and a "Go to moment" action that opens the day and scrolls/highlights the item from `TimelineLocator`. Add "Where was I…" natural inputs later (Search, WS8).
- Tracking status banners stay, but move below the header and use the compact style.

Implementation
1. New `Moves/TimelineTabView.swift` composed of `DayHeaderView`, `DayMapHero` (evolve `DayMapStrip`; keep its snapshot cache `DayMapRouteCache` for collapsed rendering), `StorylineList`, `ActivityBubblesView`.
2. `DayMapHero`: `Map` with `MapPolyline(coordinates:).stroke(gradient, style:)` per `RenderedRoute`; dashed `StrokeStyle` for `.estimated`; raw‑fix dots as small `Annotation`s when zoomed past a threshold; selection binding shared with the list (`TimelineMapSelection` already exists).
3. `StorylineRow` gains `TimelineRowStyle` (place / move / hiddenStops / carryOver / live) and exposes `onSelect`. Row content moves into small subviews to keep body cheap; day content continues to load via `DayTimelinePage.loadDayTimeline()`.
4. `ActivityBubblesView` uses `DayTimelinePageContent.transportSummaryMetrics(for:)` (make it internal) for data.
5. `MovesJumpToDateView`: add `includesTime` and `onSelectMoment(Date)`; `TimelineTabView` handles `moves://at/…`.
6. Landscape: reuse `LandscapeSplitView` with `DayMapHero` as the map pane.

Acceptance: today's day renders map + storyline + bubbles in one scroll; each mode has a distinct color; estimated legs are dashed; jumping to a time highlights the right row; 60fps scrolling on a day with 30 items on iPhone 17 (no MapKit re‑layout on scroll — the hero must not re‑create polylines on every state change; memoize `RenderedRoute`s by `dayKey` + move signature as `DayMapRouteCache` does).

Tests: snapshot tests are not in place; add unit tests for `TimelineLocator` interpolation and for bubble sizing math (`MovesTests/TimelineTabTests.swift`).

Owns: `MovesTimelineViews.swift`, `MovesJumpToDateView.swift`, new `TimelineTabView.swift`. Depends on WS0.

---

### WS2 — Corrections & Review  *(Milestone 1)*

User stories
- "It thinks I stopped at the light; one tap says 'not a stop' and the walk becomes continuous."
- "It labeled the café next door; I pick the right name from a short list and it remembers."
- "It says car but I cycled; swipe and change it."
- "I can always undo."

UX spec
- **Swipe** on storyline rows: trailing = Delete (destructive, confirm only for visits > 1h); leading = Rename (place) / Mode (move).
- **Long‑press / context menu** on a place: Rename…, Pick nearby place…, Not a stop, Merge with previous / next, Split…, Edit times…, Delete. On a move: Change mode ▸ (submenu), Path ▸ (Auto / Recorded / Roads / Manual — WS4), Split here…, Merge with previous / next move, Delete.
- **Rename sheet**: text field + "Nearby" section: up to 5 candidates = your `KnownPlace`s within 250 m (sorted by learned ranking, WS5) then Apple POIs / addresses (`MKLocalSearch` around the coordinate). Picking a candidate assigns/creates a `KnownPlace` and logs a `PlaceCorrectionEvent`. A toggle "Always use this name here" is implicit (it *is* the learning) — no extra control.
- **Edit times**: two time pickers with the neighbouring items' bounds enforced; adjusting a visit's departure adjusts the following move's start.
- **Undo pill**: bottom‑floating capsule "Renamed · Undo" for 5 s after any correction (`AppUndoController` already exposes the manager; add `UndoToastPresenter`).
- **Review inbox**: `ReviewInboxView` reachable from a badge on the Timeline tab and `moves://review`. Sections: Ambiguous places ("Home or Gym?" chips), Possible false stops (< 4 min, in/out headings within 30°), Uncertain modes (classifier confidence < 0.6 — expose from `CoreMotionTransportClassifier`), Approximate imports. Each item has inline actions and a Dismiss. Items are computed on demand from flags (`reviewState == .pending`), never a separate queue that can go stale.

Implementation
1. `StorylineRow` modifiers: `.swipeActions`, `.contextMenu`, wired to `TimelineEditController` (new `@Observable` class, one per `TimelineTabView`) that calls repository methods and posts undo toasts.
2. `PlaceRenameSheet` (new) with `NearbyPlaceSuggester` (new): merges `KnownPlace` candidates and `MKLocalSearch` results; excludes `rejectedAutoLabels`.
3. `EditTimesSheet`, `SplitSheet` (time slider over the item's span with map preview using `TimelineLocator`).
4. Repository: implement §6.3 correction methods (WS0 provided stubs/tests); `dissolveVisit` must re‑run `RoadRouteMatcher` for the merged move and clear caches (`clearCachedRouteCoordinates`).
5. Flags: extend `DefaultTimelineAssembler.ingestVisit` to set `reviewState = .pending` for short stops and low‑confidence modes; `CoreMotionTransportClassifier.classifyTransport` returns `(mode, confidence)`.
6. `UndoToastPresenter` + `.undoToast()` view modifier on `MovesRootView`.

Acceptance: every listed action works from the row without opening detail; all are undoable; "Not a stop" yields one continuous move with recomputed distance/mode; rename suggestions appear within 300 ms for known places (POIs may stream in later).

Tests: repository editing tests (WS0 file), `NearbyPlaceSuggesterTests` with an injected fake `MKLocalSearch`, classifier confidence tests in `TimelineAssemblerTests.swift`.

Owns: new `TimelineEditController.swift`, `PlaceRenameSheet.swift`, `EditTimesSheet.swift`, `ReviewInboxView.swift`, `UndoToast.swift`; correction methods in `VisitedLocation.swift` (coordinate with WS0); classifier confidence in `LocationChange.swift`. Depends on WS0.

---

### WS3 — Route rendering: colors & speed shading  *(Milestone 1)*

User stories
- "Every leg is colored by mode everywhere I see a map."
- "Brighter where I was faster, so I can see the sprint and the traffic jam."

Implementation
1. `RenderedRoute` gains `speedFractions: [Float]?` (0…1 per vertex) and `confidence: RouteMatchConfidence`. `tint` rule: base = `MovesPalette.transport(mode)`; Health and route‑tracking no longer replace the color — they set `confidence = .recorded` (solid) and add a thin white inner stroke so the "recorded" state stays recognisable.
2. `SpeedProfileBuilder` (new, in `MovesRouteSupport.swift`): given matched coordinates and the move's `samples` (use `LocationSample.speed` when ≥ 0, else distance/Δt between consecutive samples), produce per‑vertex speed by nearest sample in time, smooth with a 5‑vertex moving average, normalise by `TransportMode.typicalSpeedRange`, store in `MoveSegment.speedProfileData` alongside `routeCacheSignature` so it invalidates with the route.
3. Gradient stroke: `MapPolyline(coordinates:).stroke(Gradient(stops:), style:)` with stops at cumulative‑distance fractions; lightness via `MovesPalette.speedShade`. Known MapKit‑for‑SwiftUI quirks (verified Sep 2026): the gradient must be a plain `Gradient` (not `LinearGradient`); **all stop colors must be opaque** or the whole line renders in the first color; and polylines with hundreds of stops re‑render sluggishly on pan/zoom. Therefore: quantise speed into ≤ 16 stops per polyline (merge adjacent vertices with the same bucket), express "75% opacity" states as opaque colors pre‑blended toward the map background rather than alpha, and keep a `UIViewRepresentable` + `MKGradientPolylineRenderer` fallback behind a feature flag if the SwiftUI path still lags on G17. For MapKit snapshot rendering (`DayMapStrip.renderCollapsedSnapshotOverlay`, share cards) draw per‑segment strokes in Core Graphics with the same bucketed colors.
4. Dashed style for `.estimated`, dotted for `.photoInferred`. Central `RouteStrokeStyle.make(for: RenderedRoute)`.
5. Setting: `@AppStorage("map.shadeRoutesBySpeed")` default `true`; the Timeline collapsed header ignores it.
6. Apply the same palette in `DayTransportSummaryView`/bubbles, `MovesShareDesign`, Watch `WatchMovesContentView`, widgets.

Acceptance: a walking leg, a cycling leg and a car leg on the same day are visually distinct on Timeline, Map and share cards; speed shading visible on a route‑tracked walk; no gradient work on the main thread beyond building `Gradient` stops (profile computed off‑main with the route match).

Tests: `SpeedProfileBuilderTests` (normalisation, smoothing, missing speeds).

Owns: `MovesRouteSupport.swift` (except `RoadRouteMatcher` which WS4 owns), palette usage in `MovesShareViews.swift`, `Moves Widgets/TimelineWidgetViews.swift`, `Moves Watch App/WatchMovesContentView.swift`. Depends on WS0.

---

### WS4 — Snapping policy & confidence  *(Milestone 1 for the per‑segment switch; algorithm work continues into M2)*

User stories
- "Routes follow the actual roads and paths when the data supports it, and are honest when it doesn't."
- "If a leg snapped wrong, I switch that leg to Recorded or Manual and it stays that way."
- "I can set how aggressive snapping is overall."

UX spec
- Move detail **Path** control: segmented `Auto · Recorded · Roads` + `Manual` appears once the user drags. Below it one line from `routeMatchSummary` and a confidence glyph. Raw fixes always drawn as faint dots in detail.
- Settings → Map: **Snapping** `Conservative · Normal · Off` (`@AppStorage("routing.snappingLevel")`).

Algorithm (implement in `RoadRouteMatcher`, keep the existing memo/limiter/plausibility structure)
1. **Never snap** plane, boat, swimming; train only to rail via `MKDirectionsTransportType.transit` is unreliable → treat train as Recorded/Estimated (straight segments between fixes).
2. **Density gate**: fixes per km = intermediate samples / recorded km.
   - ≥ 5/km (route tracking, Health, dense imports): match window by window (consecutive fix pairs ≤ 400 m apart through `MKDirections`, `requestsAlternateRoutes = true`, pick by `RouteMatchPlausibility.selectionScore`), accept only if `isAcceptable` with the **mode corridor** (walking 25 m, cycling 35 m, automotive 60 m, scaled by median `horizontalAccuracy`). Confidence `.high`. On any rejected window, keep that window's raw fixes (do not discard the whole route).
   - 1–5/km (typical significant‑change data): one directions request through all fixes as waypoints (current behaviour) but accept only if matched length ≤ 1.3 × chained straight‑line length **and** every intermediate fix is within corridor × 2. Confidence `.medium`.
   - Endpoints only (< 1/km, most low‑power moves): request directions **only** if both endpoints are places and mode ∈ {automotive, cycling, walking} and straight‑line distance ≥ 300 m; label `.estimated` (dashed). Under `Conservative`, skip this and draw dashed straight lines. Under `Off`, never call directions.
3. **Walking off‑network**: if ≥ 30% of fixes are > corridor from any candidate path but self‑consistent (speed plausible), keep raw for those windows; summary "Partly off‑path (park/beach)".
4. **Rejection memory**: a rejected match is memoised per `cacheSignature` so we do not re‑request on every render (`RouteMatchMemo.storeTransient` exists; add a `rejected` case with 24h TTL).
5. `routeMatchSummary` composed from window stats: "Matched to roads · 94% of fixes within 12 m", "Estimated: no fixes between places", "Recorded (route tracking)", "Manual".
6. Policy precedence in `resolveDisplayedCoordinates`: `.manual` → `.recorded` → `.roads` (force directions even if plausibility fails, still mark confidence) → `.auto` (above).
7. Directions budget: `DirectionsRequestLimiter` already throttles; add a per‑day cap and defer background matching to a `BGProcessingTask` for imports.

Acceptance: switching Path on a leg persists across relaunch and re‑processing; a two‑point car leg shows dashed under Conservative and solid‑lighter under Normal; a route‑tracked walk through a park keeps its raw path where no footpath exists; no directions requests when Snapping = Off.

Tests: `RouteMatchPolicyTests` using recorded fixtures in `MovesTests/Fixtures` (add three: dense walk, sparse car, park walk) with a fake `DirectionsProvider` protocol injected into `RoadRouteMatcher` (introduce the protocol; production wraps `MKDirections`).

Owns: `RoadRouteMatcher`, `RouteMatchPlausibility`, `RouteMatchMemo`, `DirectionsRequestLimiter` in `MovesRouteSupport.swift`; Path control in `MovesDetailViews.swift`; Map settings section in `MovesSettingsView.swift`. Depends on WS0.

---

### WS5 — Place learning  *(Milestone 2, algorithm can start after WS0)*

User stories
- "After I fix a place once, future visits there get the right name."
- "When two of my places are close together, it asks instead of guessing wrong."
- "It stops offering the wrong address once I've rejected it."

Algorithm (`PlaceLearningEngine`, new file, pure functions + a small actor; called from `DefaultTimelineAssembler.ingestVisit` after `addOrUpdateVisit` and from imports)
1. **Candidates**: `KnownPlace`s where distance(center, visit) ≤ footprintRadius + max(visit.horizontalAccuracy, 20) + 15.
2. **Zero candidates** → leave `assignmentSource = .none`; reverse‑geocode as today, but suppress any `rejectedAutoLabels` from places within 250 m.
3. **One candidate** → assign `.auto`, confidence = 1 − distance / (footprintRadius + accuracy), clamped 0.5…1.
4. **Multiple candidates** → score each:
   `s = 0.45·proximity + 0.20·hourAffinity + 0.10·weekdayAffinity + 0.15·durationAffinity + 0.10·prior`
   where proximity = 1 − d/(r+acc), hourAffinity = normalised `arrivalHourHistogram[hour]` (with ±1h smoothing), weekdayAffinity likewise, durationAffinity = likelihood of the visit's stay under the place's duration samples (if departure known, else 0.5), prior = confirmedVisitCount / Σ candidates.
   If top − second ≥ 0.25 → assign `.auto` with confidence = margin‑based and show the "auto" mark (user can still flip it); else assign top as `.autoAmbiguous`, `reviewState = .pending`, and the row shows a chooser with the top two. This margin is a **decided** product rule, not a guess.
5. **Learning**: only `.user` assignments (rename, pick, chooser tap) update the `KnownPlace`: recompute center as mean of confirmed visits (cap 200 most recent), radius = clamp(p90 distance × 1.15, 25, 150), histograms +1, duration sample appended. Auto assignments never mutate the place.
6. **Negatives**: a correction *away* from an auto label appends it to the destination place's `rejectedAutoLabels`; a correction away from a `KnownPlace` A to B where A's footprint contained the visit records a `PlaceCorrectionEvent`; after 3 such events A's radius shrinks by 20% (min 25 m).
7. **Merging**: Places tab "Merge into…" reassigns visits and unions histograms.
8. **Migration** of `inferredUserLabel(near:)` (imports) to `PlaceLearningEngine.resolve` so imports and live capture share one path.

UX: "auto" mark on assigned rows; chooser chip for ambiguous; Review inbox section; Places detail shows the footprint circle with a "Shrink footprint" action.

Acceptance: correcting a visit once labels the next visit there automatically; two confirmed places 60 m apart produce a chooser rather than a silent guess **until** the ranking margin is ≥ 0.25, after which the winner is auto‑assigned with an "auto" mark; rejected geocoder names stop appearing; engine is deterministic and unit‑tested on synthetic histories.

Tests: `PlaceLearningEngineTests` (single/multi‑candidate, learning updates, negatives, ambiguity margin), `TimelineAssemblerTests` integration.

Owns: new `PlaceLearningEngine.swift`; hooks in `LocationChange.swift` (`DefaultTimelineAssembler`), `VisitedLocation.swift` (`inferredUserLabel` replacement), import call sites. Depends on WS0; UI pieces depend on WS2/WS7.

---

### WS6 — Map tab  *(Milestone 2)*

User stories
- "Show today by default; two taps to see this afternoon 13:00–18:00, last week, or all of 2025."
- "Toggle car off and see only my walks; switch to heat or fog."

UX spec
- **Range pill** (top center, glass): "Today", "Sat 13:00–18:00", "Last week", "Sep 2026", "2025", "All time". Tap → `MapRangeSheet` with presets (Today, Yesterday, This week, Last week, This month, Last month, This year, All time) + custom start/end pickers. Chevrons on the pill step the current granularity (day/week/month/year) backwards/forwards.
- **Scrubber** (bottom, above tab bar): axis matches granularity (24h for a day, 7 days for a week, days for a month, months for a year, years for all time) with a mini histogram of moving minutes. Two handles select a sub‑range; drag the middle to slide; pinch to change granularity; double‑tap to reset to full range. Live label shows the selected span.
- **Chips** (bottom‑left over map): mode filters (multi‑select, colored), layer picker (Routes · Heat · Fog). "Share" button renders the current selection via `MovesShareGalleryView`.
- Tapping a route → callout with date/time, mode, distance; "Open in Timeline" deep‑links to `moves://at/…`.

Implementation
1. New `Moves/MapTab/` files: `MapTabView.swift`, `MapRangeSelection.swift` (`struct { interval: DateInterval; granularity: MapGranularity }`, `presets`, `step(by:)`), `MapRangePill.swift`, `MapRangeSheet.swift`, `MapTimeScrubber.swift` (Canvas‑drawn histogram + two `DragGesture` handles), `MapLayerChips.swift`, `MapWindowLoader.swift`.
2. `MapWindowLoader` (`@Observable`): for ≤ 7 days fetch `MoveSegment`s/`VisitPlace`s via repository range queries and build `RenderedRoute`s through `RoadRouteMatcher` (respecting policy; do **not** trigger new directions requests for ranges > 7 days — use cached/raw only). For month/year/all use `ShareMapAggregateStore` polylines (already computed for share cards; extend `ShareMapAggregateTrack` with `transportMode` and a per‑day bucket so the scrubber histogram and mode filters work), and refine to per‑move routes when the user zooms in past a threshold.
3. Layers: Routes = polylines (WS3 styles); Heat = `MKTileOverlay` subclass rasterising `VisitedCell` counts with a log color ramp (or, simpler first cut, `MapPolyline` at low alpha with additive stacking); Fog = `MKTileOverlay` drawing a dark mask with cleared cells. **Adaptive fog (decided):** persist `VisitedCell` at ~100 m (`0.001°`, already in the model). At city zoom, aggregate 3×3 cells (~250 m) before punching holes so the overlay is cheap; at street zoom, draw the native 100 m cells. `VisitedCellStore` updates incrementally from `LocationSample` inserts (hook in `SwiftDataTimelineRepository.appendSamples`) and has a rebuild job.
4. Speed shading on by default here (WS3).
5. Persist last range per session only; app always reopens on Today.

Acceptance: default Today; selecting 13:00–18:00 on the scrubber filters routes; week/month/year render within 1 s from aggregates on a 3‑year dataset; mode chips filter; fog and heat layers render; range → Share produces the right card.

Tests: `MapRangeSelectionTests` (presets, stepping across DST/month ends), `VisitedCellStoreTests`.

Owns: `Moves/MapTab/*`, `ShareMapAggregate.swift` extension (coordinate with share‑card owner if any). Depends on WS0, WS3.

---

### WS7 — Places tab  *(Milestone 2)*

User stories
- "See every place I actually go, grouped by country and city, with how often and how long."
- "Open Home and see when I'm usually there; merge duplicates; fix the footprint."
- "When did I last visit this café?"

UX spec
- List: sections by country (flag emoji from `countryCode`) → city, rows: name, visit count, total time, last visit. Sort: most visited / most time / recent / A–Z. Search field filters names.
- Detail: header with name/category, mini map with footprint circle, stats (visits, total time, average stay, first/last), **occupancy chart** (7×24 heat grid from `arrivalHourHistogram`/`weekdayHistogram` and actual visits), recent visits list (→ `moves://day/…`), actions: Rename, Set category (Home/Work/Gym/Other), Merge into…, Shrink footprint, Delete place (unassigns visits; never deletes visits).
- Unassigned visits (no `KnownPlace`) appear under "Suggested" with a one‑tap "Confirm" that creates a place — this is the main on‑ramp for learning.

Implementation
1. `Moves/PlacesTab/PlacesTabView.swift`, `PlaceDetailView.swift`, `OccupancyChartView.swift` (Swift Charts `RectangleMark`), `PlacesIndex` (`@Observable`, builds grouped data off‑main from `KnownPlace` + unassigned `VisitPlace` clusters).
2. Geocode backfill job `PlaceGeocodeBackfill` (BGProcessingTask + foreground trickle, rate‑limited 1 req/s): fills `countryCode`/`locality`/`administrativeArea` on `VisitPlace` and `KnownPlace` via `CLGeocoder`; persist a per‑0.01° cache to avoid repeats.
3. Retire the "Statistics · Visits" segment of `MovesStatisticsSearchView`; keep "Connections" and move it under Insights (WS8).

Acceptance: places grouped by country/city on a dataset spanning ≥ 2 countries; confirm/rename/merge update Timeline rows immediately; occupancy chart reflects visits.

Owns: `Moves/PlacesTab/*`, `PlaceGeocodeBackfill.swift`. Depends on WS0, WS5.

---

### WS8 — Insights tab & Search  *(Milestone 3)*

User stories
- "How much did I walk/bike/drive this year vs last?" "How many countries and cities?" "Longest streak of active days?"
- "Search: 'Berlin', 'coffee', 'Tue 3pm', 'last Christmas'."

UX spec
- Year selector chips (current year default; "All"). Cards: **Activity grid** (per mode: duration, distance, Δ vs previous year — Arc's layout); **Countries & Cities** counts with a tappable list; **Activity calendar** (GitHub‑style, colored by distance); **Streaks** (current/longest active days, "active" = any move ≥ 500 m); **Monthly distance** bars; **Time of day** and **weekday** patterns; **Connections** (existing feature, moved here); **Year in review** share button → `MovesShareGalleryView` (Years period).
- Search (toolbar on Timeline/Places): unified results — Places (name/category/city), Days (date phrases via `DateFormatter` + light NL parsing: "last Tuesday", "Christmas 2024"), Moments ("Tue 3pm" → `moves://at/…`), Notes (comments).

Implementation
1. `Moves/InsightsTab/InsightsTabView.swift`, `InsightsSnapshot.swift` (`struct` computed off‑main; cache per year in a `@Model InsightsYearCache` *or* recompute on demand if < 300 ms on a 5‑year dataset — measure first), reuse `DayTimelinePageContent.transportSummaryMetrics(for:)` and `MovesStatisticsSnapshot` builders.
2. Charts with Swift Charts; all numbers through `MovesStatisticsFormatting`.
3. `MovesSearchView.swift` + `SearchQueryParser` (date/time phrases → `DateInterval`/`Date`), results feed existing deep links.
4. Move `Connections` UI out of `MovesStatisticsSearchView` and delete that view when empty.

Acceptance: Insights for a year renders < 300 ms from cache; deltas correct across year boundary; search finds a place by city, a day by phrase, and a moment by time.

Tests: `InsightsSnapshotTests` (streaks, deltas, active‑day rule), `SearchQueryParserTests`.

Owns: `Moves/InsightsTab/*`, `MovesSearchView.swift`, `MovesStatisticsSearchView.swift` (retire). Depends on WS0, WS7 (country/city fields).

---

### WS9 — Photos  *(Milestone 3)*

User stories
- "Photos I took show up on the visit where I took them."
- "Rebuild the years before I tracked from my photo library, clearly marked as inferred."

UX spec
- Settings → Photos: "Show photos on visits" toggle (requests `PHPhotoLibrary` `.readWrite` access — iOS has no read‑only level; explain that we never modify photos; support Limited Library). Below: "Rebuild history from photos…" → sheet with date range (default: before first recorded day), preview counts ("2,318 geotagged photos → ~412 visits in 19 countries"), Import button, progress, and a report. Re‑running is idempotent.
- Timeline place rows show up to 4 thumbnails + "+N"; tap → grid → tap → full‑screen `PHAsset` viewer (read‑only). Photo‑inferred visits use the dotted style and a camera glyph; their moves are `.estimated` with mode `.unknown` unless speed implies plane (> 200 km/h between clusters ⇒ `.plane`).
- Onboarding (WS10) offers this import on day one.

Implementation
1. `PhotoLibraryService` (actor): authorization, `PHAsset` fetch by `creationDate` range with `location != nil`, thumbnails via `PHCachingImageManager`, change observer to attach new photos to today's visits.
2. **Attachment** (ongoing): for each new geotagged asset, find the `VisitPlace` whose [arrival, departure] contains `creationDate` (±10 min) and whose coordinate is within 300 m; else attach to the day only. Store `PhotoAttachment`.
3. **Backfill importer** `PhotoHistoryImporter` (reuse `LocationLogSegmenter` from `LocationLogImport.swift` once it lands — it already turns sparse timed points into stays/trips): convert assets to timed points, segment with photo‑appropriate thresholds (new stay when gap > 90 min **or** distance > 500 m; stay needs ≥ 2 photos or ≥ 20 min span), create `VisitPlace`s with `origin = .photoInferred`, samples with `.photoLibrary`, run through `PlaceLearningEngine`, attach the photos. Never overwrite sensor days: on overlap, only attach photos.
4. Privacy: photos never leave the device; share cards never include photos unless the user adds them explicitly (future); Spotlight donation unchanged.

Acceptance: a photo taken at a recorded visit appears on that row within a minute of returning to the app; backfill of a 10k‑photo library completes in the background with progress and produces inferred days that render dotted; re‑import creates no duplicates.

Tests: `PhotoHistoryImporterTests` with synthetic assets (protocol `PhotoAssetProviding`).

Owns: new `Moves/Photos/*`, thumbnails strip in `StorylineRow` (coordinate with WS1), Settings section. Depends on WS0, WS1, WS5, and the LocationLog segmenter WIP.

---

### WS9b — Named trips  *(Milestone 3, after or alongside WS9)*

User stories
- "Save 'Japan 2024' as a trip and reopen it later with the map, days, notes, and photos."
- "On the Map tab, after selecting a range, tap Save as trip."

UX spec
- A trip is a named `DateInterval` plus optional notes. It does **not** copy points; it is a lens over existing visits/moves/photos in that range (same as Dawarich). Deleting a trip never deletes timeline data.
- **Trip list** (reachable from Insights and from Map's Share/Save): name, date range, distance, countries, cover photo (first geotagged photo in range, or none).
- **Trip detail**: sticky map of the range (reuse `MapTabView` loader), day-by-day accordion (reuse Timeline day rows), notes field, photo strip from `PhotoAttachment`s in range (WS9). "Open in Map" applies the range to the Map tab.
- **Create**: Map tab range pill menu → "Save as trip…"; Insights year card → "Save year as trip" is *not* needed. Name defaults to the range's locality if one city dominates, else the date span.
- Replay of a trip (Dawarich scrubber) is **out of scope for M3**; the Map scrubber already covers playback-by-range.

Implementation
1. Additive `@Model NamedTrip` (`id`, `name`, `startDate`, `endDate`, `notes`, `createdAt`). Land in the WS9b PR, not WS0 — CloudKit-safe defaults, optional everything.
2. `Moves/Trips/TripListView.swift`, `TripDetailView.swift`, `SaveTripSheet.swift`. Range queries via `TimelineRepository.moves(in:)` / `visits(in:)`.
3. Deep link `moves://trip/{uuid}`.

Acceptance: saving a five-hour Map range creates a trip that reopens with the same routes and any photos in that window; deleting the trip leaves the days intact.

Owns: `Moves/Trips/*`, `NamedTrip` in `VisitedLocation.swift`. Depends on WS0, WS6 (range), WS9 (photos on the trip).

---

### WS10 — Imports & onboarding  *(Milestone 4)*

User stories
- "Bring my Google Timeline history into Moves in one go."
- "The first launch tells me what the app does, why it needs Always location, and offers to import."

Google Timeline JSON — support all three shapes, auto‑detected by top‑level keys:
1. **Takeout `Records.json`**: `locations[]` with ISO `timestamp` (**not** `timestampMs`). Coordinates are `latitudeE7`/`longitudeE7`. Fields vary by era: `source`; nested `activity[]`; later often only E7 lat/lng + `accuracy` + `deviceTag` + `timestamp`. → samples (`.googleTimelineImport`), then segment with `LocationLogSegmenter` to fill months that semantic history missed.
2. **Takeout Semantic Location History** `YYYY_MONTH.json` in year folders: `timelineObjects[] { placeVisit { location { latitudeE7, longitudeE7, name, address, placeId, semanticType }, duration { startTimestamp, endTimestamp } } | activitySegment { startLocation, endLocation, duration, activityType, activities[], distance, waypointPath | simplifiedRawPath | transitPath } }`. Timestamps are ISO (**not** `*Ms`). `simplifiedRawPath` appears on **both** `activitySegment` and some `placeVisit`. Visits get `autoLabel = name` (never put street `address` in Spotlight). Moves map mode (`WALKING→walking`, `CYCLING→cycling`, `IN_PASSENGER_VEHICLE|IN_VEHICLE|MOTORCYCLING→automotive`, `IN_TRAIN|IN_SUBWAY|IN_TRAM|IN_BUS→train`, `FLYING→plane`, `IN_FERRY|SAILING→boat`, `RUNNING→running`, `UNKNOWN_ACTIVITY_TYPE` and anything else → `unknown`). Prefer `waypointPath.waypoints[]` (`latE7`/`lngE7`); else `simplifiedRawPath.points[]`. `travelMode` WALK/DRIVE/BICYCLE is a hint on the path, not a second source of truth. Missing top‑level `activityType` → `activities[0]`. Empty start/end locations: still import the segment if a path exists, else skip. `childVisits` → extra stays. `parkingEvent` ignore or keep as a point. `USER_CONFIRMED` placeVisits are high‑confidence labels.
3. **On‑device export `Timeline.json`** (Android) and the **iOS bare array** variant: `semanticSegments[] { startTime, endTime, visit { topCandidate { placeLocation { latLng: "50.05°, 14.34°" }, semanticType, placeId } } | activity { start.latLng, end.latLng, topCandidate.type, distanceMeters } | timelinePath[] { point: "geo:50.05,14.34" | "50.05°, 14.34°", time } }`, plus optional `rawSignals[] { position { LatLng, timestamp, accuracyMeters, speedMetersPerSecond } }`. Parse both coordinate encodings; numbers may be strings. Prefer `rawSignals` for samples when present, `timelinePath` otherwise. **Not in Roger's 2024 Takeout** — needs a later Maps app export; ship a synthetic fixture so the parser is tested anyway.
Mark all as `origin = .imported`, `transportModeSource = .imported`, `routeMatchConfidence` from path density (WS4 rules), and run `PlaceLearningEngine`.

`IN_BUS`: map to **`train`**. There is no `bus` `TransportMode` (palette in §5); do not add one in this workstream. `unknown` is the alternative if a given UI would rather not stretch train onto buses.

#### Roger's 2024 Takeout (catalogued 2026-09-20)

Already extracted (no zip) at `/Volumes/Extreme SSD/onedrive/backups/Google Location History as of Dec 1 2024`. Product folder `Location History (Timeline)/`. No KML.

| File | What it is |
|---|---|
| `Records.json` | ~308 MiB, pretty‑printed, **1,016,388** points. First **2010-06-24**, last **2021-09-21**. |
| Semantic Location History | **102** monthly JSON files, year folders 2010–2022 (gaps). ~11k `placeVisit` + ~15k `activitySegment`. |
| `Settings.json` | Metadata only (`timelineDeletionTime` **2024-06-03**). **Do not import.** |
| Shape 3 `Timeline.json` | **Absent.** GPX in `import-staging/` covers 2025–2026. This dump has **no 2023–2024** history. |

Recommended import order: folder picker on `Location History (Timeline)/` → semantic months first → stream `Records.json` (**never** `JSONSerialization` the whole file) → skip `Settings.json` and `archive_browser.html`. Keep `.zip` / single‑`.json` pickers for other Takeouts and for shape 3.

Arc Timeline JSON: **out of scope until a real export exists.** Do not ship a guessed parser. If a file later lands in gitignored `import-staging/`, add `ArcTimelineImporter` then (v3 and v4 formats differ; verify against the file). Settings may omit the Arc row entirely for M4.

Implementation
1. `Moves/Import/GoogleTimelineImporter.swift` (+ `GoogleTimelineDocument` decoders for the three shapes). Produce the intermediate `[LocationLogStay] / [LocationLogTrip]` used by `LocationLogImport` so persistence, dedupe, and progress reporting are shared (`SwiftDataTimelineRepository.upsertLogStay` etc.).
2. Settings → Import: add row "Google Timeline" with format hints. **Primary picker is a folder** aimed at `Location History (Timeline)/` (or the dated Takeout parent). Also accept `.json` (Records, one semantic month, or on‑device Timeline) and `.zip` (unextracted Takeout — unzip Semantic Location History on the fly). Ignore `Settings.json` and `archive_browser.html`.
3. Stream `Records.json` (~308 MiB pretty‑printed here; other Takeouts can exceed 1 GB): scan the `locations` array with an `InputStream` / token scanner. **Never** `JSONSerialization` the whole file. Semantic months max ~1.5 MB — whole‑file decode is fine.
4. **Onboarding** `OnboardingFlow.swift` (three pages, shown when `dayTimelines.isEmpty && !hasSeenOnboarding`): what Moves records; permissions with plain‑language cost ("Always location lets Moves notice arrivals and departures; it uses the low‑power visit monitor, not GPS"); "Bring your history" with Google / Photos / Health / Files buttons and Skip. Motion permission requested on first move, not in onboarding.

Acceptance: Roger's Takeout folder imports without duplicates and shows mode‑colored, dashed‑where‑estimated days (semantic first, Records filling gaps); 1.02M‑point `Records.json` streams without memory warnings; a later on‑device `Timeline.json` still imports; onboarding appears once.

Tests: fixtures under `MovesTests/Fixtures/GoogleTimeline/` (describe now; add the files when implementing — do not create them in a docs‑only pass). Keep them small; round coords; no street addresses. `GoogleTimelineImporterTests`.
- `records-mini.json` — four points covering `source: wifi` / `WIFI`, nested `activity[]`, and a late deviceTag‑only ISO `timestamp` record.
- `semantic-month.json` — `TYPE_HOME` visit; WALKING + `waypointPath`; IN_PASSENGER_VEHICLE + `parkingEvent`; IN_BUS + `transitPath` + `simplifiedRawPath`; FLYING; empty start/end with `activities[0]`; `childVisits`; `placeVisit` with `simplifiedRawPath`; `USER_CONFIRMED`.
- `timeline-ondevice.json` — **synthetic** (not from this disk): both `latLng` encodings + `rawSignals`.
- `not-google.json` — `{ "foo": 1 }` so auto‑detect fails closed.

Owns: `Moves/Import/*`, `OnboardingFlow.swift`, Import section of `MovesSettingsView.swift`. Depends on WS0, WS5, and the LocationLog WIP.

---

### WS11 — Getting data out: webhook, zip export, Shortcuts  *(Milestone 4)*

- **Webhook destination** in Integrations (`DawarichSync.swift` pattern): URL, optional bearer header, HTTPS required except local network. Same "new points only / backfill needs confirm" rule. **Two payloads (decided):**
  1. **OwnTracks-compatible** `_type: location` (and optional `_type: transition` on visit arrive/leave) so Recorder, Home Assistant, and similar ingest without a custom parser. Reuse the GeoPulse/OwnTracks encoding already in `DawarichSync.swift` where possible.
  2. **Moves-native** JSON `{ visits: [...], moves: [...] }` with ids, mode, place names, times, and a simplified route (not full sample dumps by default). Toggle which envelopes to POST (both on by default).
- **Export everything**: one button producing a zip (GPX + GeoJSON + CSV + `places.json` with `KnownPlace`s + `photos.csv` of attachment identifiers) via `ZIPFoundation`‑free `Compression`/`NSFileCoordinator`… simplest: write files into a temp folder and use `FileManager` + `NSFileCoordinator` to produce a `.zip` through `UIDocumentInteraction`; alternatively ship an uncompressed folder to Files. Decide at implementation; keep `TimelineArchiveImport` able to read it back.
- **KML export** (Google Earth users; original Moves had it) in `MovesShareViews` GPX exporter family.
- **Shortcuts**: `VisitEntity` and `MoveEntity` App Entities with queries by date range; "Get Visits", "Get Moves", "Where Was I At" intents returning place name + time (never coordinates unless the user opts in per intent). Calendar sync of visits (EventKit, opt‑in, own calendar "Moves").

Owns: `DawarichSync.swift` (webhook), `MovesAppIntents.swift`, export code in `MovesSettingsView.swift`/`MovesShareViews.swift`. Depends on WS0.

---

### WS12 — Polish & platform  *(rolling)*

- Widgets draw the route from `TimelineWidgetSnapshot.routePoints` with `Canvas` (mode color, no map tiles).
- Settings → iCloud: CloudKit sync status (from `CloudDataPresencePublisher`), last sync, "Local only" fallback explanation, link to Daily Backup.
- Privacy zones: circles (default 200 m around Home/Work categories) that blur on share cards and hide raw fixes in exports when toggled.
- Live Activity shows current mode color and distance; Watch map uses the palette.
- Accessibility pass: every gesture has a menu path; VoiceOver labels on map elements; charts have `accessibilityChartDescriptor`.
- Localisation: all new strings through `Localizable.xcstrings`.

---

## 8. Milestones

| Milestone | Workstreams | Outcome the user sees |
|---|---|---|
| **M0 Foundations** | WS0 | Tab bar with four tabs; schema + upgrader; palette; repository editing API. |
| **M1 Timeline** | WS1, WS2, WS3, WS4 (Path switch + policy tiers) | New home screen: tall mode‑colored map, storyline with swipe/long‑press corrections, Undo pill, Review inbox, time‑of‑day jump, honest route states, snapping control per leg and global level. |
| **M2 Map & Places** | WS6, WS5, WS7 | Browsable map with range pill/scrubber/layers/mode chips; learned places with ambiguity handling; Places tab. |
| **M3 Insights & Photos** | WS8, WS9, WS9b | Yearly insights, unified search, photos on visits, photo‑history backfill, named trips. |
| **M4 In & out** | WS10, WS11, WS12 | Google Timeline import, onboarding, dual webhook, zip/KML export, Shortcuts entities, widget map, iCloud status. |

Parallelism: after M0, WS1–WS4 can run as four agents (WS1 and WS2 touch `StorylineRow`; WS2 owns the actions, WS1 owns layout — agree the `StorylineRow` API in the first PR). WS5 can begin its engine in parallel with M1 since it is UI‑free until M2.

---

## 9. Engineering rules for all workstreams

- **Build/test**: `xcodebuild test -project Moves.xcodeproj -scheme Moves -destination 'platform=iOS Simulator,id=159ACCC1-78B1-4E1A-9BDE-F1315C3FE5B2'` must pass before a PR. New logic gets unit tests in `MovesTests` (XCTest, `@testable import Moves`); UI is verified on iPhone 18 Pro simulator with the demo seeder and on G17 via `Scripts/install-iphone.sh`.
- **Never hardcode** bundle IDs, App Group, iCloud container, or team (see `AGENTS.md`). Use `MovesAppIdentity`.
- **CloudKit‑safe models**: defaults on every property, optional relationships, no unique attributes, additive changes only. Removing a field requires a migration plan reviewed by Roger.
- **View identity independence**: capture, Live Activity, uploads, and SwiftData writes live above the `TabView`; tab switching, fold/rotation must not recreate `MovesLocationCaptureManager`.
- **Off‑main work**: route matching, learning, insights, imports run in detached tasks with their own `ModelContext`; the UI observes results. Respect `DirectionsRequestLimiter`.
- **Undo**: every user mutation goes through the repository and the shared `UndoManager`.
- **Privacy**: no coordinates in Spotlight or default Shortcut outputs; photos never leave the device; exports and Siri export require authentication (existing rule).
- **Strings**: user‑facing text in `Localizable.xcstrings`; sentence case; no jargon ("snapping" → "Path", "geocode" → "name").
- **Docs**: every new type has a doc comment; each workstream PR updates the "Layout" table in `AGENTS.md` if it adds a folder.
- **Branches**: `ws0-foundations`, `ws1-timeline`, …; small PRs (< 800 lines) against `main`; rebase on the LocationLog WIP once merged.
- **Do not touch**: `Moves/LocationLogImport.swift`, `MovesTests/LocationLogImportTests.swift`, `import-staging/` (user data, gitignored).

---

## 10. Resolved product questions

Recorded 2026‑09‑20. Agents must not re-litigate these.

| Topic | Decision |
|---|---|
| Ambiguous nearby places | Auto-assign when top − second ≥ 0.25; otherwise chooser. Auto-assigned rows keep an "auto" mark. |
| Timeline speed shading | Follow the Map setting. Collapsed day header is always a solid mode color. |
| Fog resolution | Adaptive: persist ~100 m cells; aggregate to ~250 m when zoomed out. |
| Named trips | M3 with Photos (WS9b). Lens over a date range; does not copy points. Replay deferred. |
| Webhook | Both OwnTracks `_type: location` and Moves-native visits/moves; both on by default, user-togglable. |
| Arc import | Skip until a real export is in `import-staging/`. Do not guess the schema. |
