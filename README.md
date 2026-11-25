# Moves: Roger Pincombe’s Version

Moves builds a private, day-by-day timeline of where you were and how you got there, on iPhone, iPad, and Apple Watch.

This is [Roger Pincombe](https://rogerpincombe.com)’s version. It is a fork of the original [Moves](https://github.com/holgerkrupp/Moves) by [Holger Krupp](https://github.com/holgerkrupp) of [Extremely Successful Apps](https://extremelysuccessfulapps.com).

| | This version | The original |
|---|---|---|
| By | [Roger Pincombe](https://rogerpincombe.com) | [Holger Krupp](https://github.com/holgerkrupp), [Extremely Successful Apps](https://extremelysuccessfulapps.com) |
| Source code | [OkGoDoIt/Moves](https://github.com/OkGoDoIt/Moves) | [holgerkrupp/Moves](https://github.com/holgerkrupp/Moves) |
| Get the app | Build it from source, below | [App Store](https://apps.apple.com/app/id6762114616) · [Website](https://extremelysuccessfulapps.com/moves/) |

The two are developed separately. Please don’t report problems with this version to the original project.

## What This Version Adds

This fork branched from the original in September 2026. Its main additions since then:

- **Four tabs:** Timeline, Map, Places, and Insights
- **Corrections:** pick a nearby place, edit times, or split and merge items, with Undo and a Review inbox
- **Places:** names learned from confirmed visits, with visit history and place merging
- **Trips:** save a date range as a named trip
- **Photos:** see photos alongside your visits, and fill in past history from photo locations, without changing your library
- **Imports:** Google Timeline, logs from other tracking apps rebuilt as places and trips, and exploration coverage from Fog of World
- **Calendar:** copy visit names and times to a dedicated calendar (off by default)
- **Privacy zones:** hide Home and Work on share cards and exports

The original has also continued to develop, and some of its later work is adapted here. [UPSTREAM.md](UPSTREAM.md) records what has been reviewed and adopted.

## Features

- Daily timeline with places and move segments
- Transport mode detection (`walking`, `running`, `cycling`, `automotive`, etc.)
- Automatic place naming (reverse geocoding) plus manual place labels
- Map previews for places and routes
- Spotlight search for visited places with deep links back to their timeline day
- AppIntent-configurable Home Screen, Lock Screen, and accessory widgets
- A route-tracking Live Activity for the Lock Screen and Dynamic Island
- Siri, Shortcuts, Spotlight suggestions, and iPhone Action button support through App Intents
- Apple Watch companion that can record routes
- Export from Settings:
  - GPX (`.gpx`)
  - GeoJSON (`.geojson`)
  - KML (`.kml`)
  - CSV (`.csv`, places + moves)
  - Everything (`.zip`)
- Background tracking support (visit monitoring + significant location changes)

## Integrations

Moves can optionally upload recorded location samples to [Dawarich](https://dawarich.app), [Reitti](https://github.com/dedicatedcode/reitti), [GeoPulse](https://geopulse.cc), [OwnTracks Recorder](https://github.com/owntracks/recorder), [Traccar](https://www.traccar.org), or your own webhook. Configure each destination independently in Settings → Integrations. Cloud and self-hosted URLs are supported, secrets are stored in the iOS Keychain, and local-network HTTP is allowed while remote servers require HTTPS. Automatic uploads only include newly recorded points; uploading existing local history requires a separate confirmation for each destination.

## Siri and Shortcuts

Moves provides App Intents for starting and stopping temporary real-route GPS tracking,
checking tracking status, controlling low-energy background tracking, getting timeline
summaries, and exporting timeline data as GPX, GeoJSON, or CSV. The most common actions
are suggested automatically in Siri and the Shortcuts app.

Example phrases include “Start route tracking with Moves”, “Stop GPS tracking in Moves”,
“What’s my Moves tracking status”, “Summarize my day with Moves”, and “Export my Moves
data”. Export requires device authentication because timeline files contain location data.

The “Toggle Route Tracking” App Shortcut is designed for the iPhone Action button: assign
it in Settings > Action Button > Shortcut to use one press for starting and stopping the
high-accuracy GPS session. Starting tracking also starts a Live Activity with elapsed time,
remaining time, and distance on the Lock Screen and Dynamic Island.

Visited places are donated as App Entities to an app-scoped named Spotlight index. Tapping a
result opens the matching day in Moves. The index includes the place name and visit time,
but deliberately excludes coordinates and comments. On iOS 27, `IndexedEntityQuery`
allows Spotlight to request targeted or full reindexing.

## Requirements

- Xcode project: `Moves.xcodeproj`
- SwiftUI + SwiftData app
- iOS deployment target in project settings: `26.0`
- Location permission (Always is recommended for background tracking)
- Motion permission (used to improve transport mode inference)

## Getting Started

1. Clone this repository: `git clone https://github.com/OkGoDoIt/Moves.git`
2. Open `Moves.xcodeproj` in Xcode.
3. Select the `Moves` scheme.
4. Choose an iPhone simulator or a physical device. For a physical device, first copy
   `Config/Moves.local.xcconfig.example` to `Config/Moves.local.xcconfig` and fill in your
   own bundle ID prefix and team.
5. Build and run.
6. On first launch, allow location access (and motion access when prompted).

## How It Works

- `MovesLocationCaptureManager` starts low-power tracking via:
  - visit monitoring
  - significant location change monitoring
- Captured data is normalized and persisted to SwiftData models:
  - `DayTimeline`
  - `VisitPlace`
  - `MoveSegment`
  - `LocationSample`
- `DefaultTimelineAssembler` links visits and samples into movement segments and infers transport mode.

## Privacy

- Timeline data is stored locally on the device and syncs to the user's private iCloud container when available.
- CloudKit backs up the timeline and restores it on a new device signed into the same Apple ID.
- Export is user-initiated from the in-app Settings screen.

## Project Structure

- `Moves/MovesApp.swift` app entry and model container setup
- `Moves/ContentView.swift` timeline UI and day paging
- `Moves/LocationChange.swift` location capture, motion classification, timeline assembly
- `Moves/VisitedLocation.swift` models and SwiftData repository
- `Moves/MapTab/`, `Moves/PlacesTab/`, `Moves/InsightsTab/` the other three tabs
- `Moves/MovesSettingsView.swift` settings and export
- `MovesTests/` unit tests

[AGENTS.md](AGENTS.md) has the full layout, signing details, and development notes.

## Running Tests

Use Xcode (`Product > Test`) with the `MovesTests` target.

If you prefer command line, run tests with `xcodebuild test` using your local Xcode setup and a simulator destination.

## Credits

- The original Moves is by [Holger Krupp](https://github.com/holgerkrupp) of [Extremely Successful Apps](https://extremelysuccessfulapps.com).
- `RouteFileKit`, `FogOfWorldKit`, and [CloudDataPresence](https://github.com/holgerkrupp/CloudDataPresence) also come from that work.
- This version is by [Roger Pincombe](https://rogerpincombe.com).
