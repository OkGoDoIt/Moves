# Upstream integration review — November 9, 2026

## Scope and agreed direction

Upstream: [holgerkrupp/Moves](https://github.com/holgerkrupp/Moves), fetched through
`1f11daf802b2a7c0a531509a3b290425bec03a38` (October 29). Common ancestor:
`4f46a9b37c7dabb0dd687ad7487b60496ed5e98d`. There are 94 upstream commits after
that ancestor. This review compares the actual implementation with fork `e88f9d2`,
not just commit subjects or textual conflicts. The concurrently active agent owns
calendar sync, Duo layout, route-edit race fixes, main, and device deployment.

Roger authorized the broader integration, then explicitly **deferred Mac browsing
and multiple recording devices**. Those remain future direction. Shared cross-device
job leases are deferred with them; the local import queue is independent of that work.

The initial safety patch is only a subset of the review. Larger features below
are not implemented by that patch. Upstream's remaining changes must remain
discoverable: do not make an `ours` merge of the entire upstream tip merely to
record that it was reviewed.

## Feature-by-feature assessment

| Area | What upstream actually provides | Fork overlap and recommendation |
| --- | --- | --- |
| Native Mac app | Native SwiftUI browser, sidebar, map, inspector, search, import workflows, menu bar import progress, keyboard commands, and help. | **Include.** Reuse its browser architecture, but share our complete schema and retain our Places, corrections, trips, and privacy rules. Do not copy the upstream schema factory, which omits several fork models and hardcodes upstream's container. Preserve our design tokens instead of adopting a second design library solely for the port. |
| Multiple recording devices | Stable installation identity, synced device presence, per-record device IDs, tracking/management roles, and a local projection choosing a representative trace. | **Include with adaptation.** Preserve every device's source observations; selection must not delete an alternate trace. Keep old unassigned history visible. Apply ownership rules to deduplication, reconciliation, undo, Watch import, uploads, and backup—not just the UI. Avoid selecting one device for an entire day when the person switches devices partway through it. |
| Shared background work | Conditional CloudKit record claims for backup, external upload, and imported-mode refinement; expiration, retry, and completion markers. | **Useful for the agreed multi-device direction, but revise the callers before enabling.** Details below. This is not needed for local map caches or each device's GPS capture. |
| Sync diagnostics and startup recovery | Early buffered CloudKit events, nested failure analysis, separate import/export observations, local record IDs/counts, recovery diagnostics, and honest system-deferral reporting. | **Include incrementally.** Adapt into our existing iCloud status and singleton store. The safety patch improves nested error handling. Early observation, per-stage state, and nonfatal startup recovery remain to integrate. Do not treat presence counts or a successful local save as proof that data reached iCloud. |
| Resumable file imports | Persisted local job queue, file staging/security-scoped access, recovery state, pause/retry, per-file progress, and background continuation. | **Include.** This fills a real gap: our file/Google import runs off the main thread but does not have this durable queue. Put our existing parsers and import writers behind the queue; keep semantic Google history, timestamped-log segmentation, privacy, and imported-origin safeguards. Do not expose overwrite-by-time-range as the default. |
| Compact imported routes | Dense imported geometry stored as a payload on a move instead of one synced model per GPS point. | **Promising, separate data-format change.** Could substantially reduce CloudKit work for large imports. Preserve original timestamps, speed, accuracy, provenance, and export fidelity; teach search, map/fog, photos, route matching, and reconciliation to read both formats before using it. Do not delete historical samples as part of this integration. |
| Bounded timeline browsing | Background day-index queries, immutable presentation snapshots, stale-request gates, progressive rows/geometry, and bounded fetches. | **Include.** Our day navigation still queries all `DayTimeline` rows. This is not fully duplicated. Compose it with the other agent's Duo layout and our correction/undo model. Port snapshots with all fork provenance/review fields. Fetch limits must offer continuation rather than silently hide history. |
| Map snapshots and large-history performance | Memory/disk snapshot cache, shared in-flight requests, cancellation, invalidation, and coarse aggregate geometry for large ranges. | **Include selectively.** Our Map tab already switches to aggregates and has load-generation protection, so retain those pieces. Reuse the bounded snapshot/cancellation ideas where measured work is duplicated. Avoid introducing a second route matcher or storing stale derived geometry after an edit. |
| Quick Look and thumbnails | Isolated GPX/TCX/KML/GeoJSON previews and thumbnails using `RouteFileKit`; Mac route-only fallback when map tiles are unavailable. | **Include with the Mac/file work.** Useful in Finder and Files without importing history. Parameterize app-group/bundle IDs, retain parser size bounds, and avoid creating a second inconsistent parser. No timeline database or location capture is needed in the extensions. |
| Raw-fix inspection | Switch between reconstructed timeline and timestamped OS-fix rows, with source, accuracy, and map selection. | **Useful addition.** Our Path setting chooses route presentation; it is not an equivalent raw-fix inspector. Add a focused inspect view using our existing source/provenance vocabulary, rather than a second primary timeline mode with different correction behavior. |
| Regular Places and visit history | Named radius-based places, editor, assignment, and paginated other-visit lookup. | **Consolidate into our Places.** `KnownPlace` already has confirmed learning, ambiguity, rejected names, categories, occupancy, merge, and footprint tools. Keep it; adapt pagination and direct “other visits” navigation as useful. Do not add `KnownLocation` as a second model for the same concept. |
| Photo-derived history | Metadata scan, inferred visits, asset links, previews, and import management. | **Mostly already present.** Keep our `PhotoAttachment`, read-only PhotoKit, and rule that photo inference cannot rewrite recorded days. Adapt bounded batching/recovery through the common import queue. |
| Writing GPS into Photos | Matches timeline locations to assets, writes PhotoKit metadata, and keeps an undo audit. | **Separate opt-in product decision.** This changes the explicit read-only library contract. It is not an incidental import improvement and is not part of the safety patch. |
| High-resolution Exploration | Local source shards, durable per-day work queue, fine raster coverage, multilevel MapKit tiles, bounded preparation, and visible-tile backfill. | **Worth adapting, not dismissing as duplicate.** Our roughly 100 m cells are simpler; upstream supports much finer coverage. Integrate as the existing Map fog layer's engine, with source-separated coverage and incremental invalidation. No second Exploration tab or always-running history scan is needed. Current upstream presentation is largely DEBUG-only. |
| Fog of World compatibility | Native archive reader/writer, tile checksums and formats, snapshot hierarchy, and separate undated imported coverage. | **Useful optional import/export.** Keep undated coverage separate from dated visits; never fabricate timeline entries. Reuse `FogOfWorldKit` with the exploration engine if selected. A package existing upstream is not evidence that it is already a polished end-user workflow. |
| Country/region insights | Bundled offline boundaries, latitude-aware explored area, country presence, manual travel evidence, and distinction between transit/visited/evidence sources. | **Integrate into our Insights when exploration is adopted.** Our country/city visit analytics already exist. Preserve their dates and provenance; do not count a flight line as a ground visit. Manual travel evidence is user data, not disposable cache. |
| Achievements/passport/flight keepsakes | Debug achievement progress, procedural passport stamps, and decorative flight-ticket artifacts. | **Optional presentation work.** Independent of recording and sync reliability. Keep behind a product/design decision; not a dependency of accurate coverage or country statistics. |
| Flight handling | Better geodesic/dateline geometry, flight fragments/merge, optional metadata and matching abstractions. The shipped historical-flight provider is a fixture/in-memory provider and the airport database is small. | **Include geometry and explicit editing carefully.** Retain recorded-vs-estimated distinction and fork undo. Do not promise automatic airline/flight-number lookup. A real provider would need its own explicit selection and privacy/cost decision. |
| Motion inference | Duration-weighted motion transitions, a sustained-walk override, route-feasibility probes for possible flights, and imported-mode refinement. | **Partially adapted now.** Adopt duration weighting; retain confidence and long-false-trip rejection. Do not blindly use the median-speed walk override: slow traffic can resemble walking. Network route probes and retroactive classification need bounded work and curated/imported protections. |
| Watch performance/delivery | Actor-owned file work, cached/downsampled route presentation, and one-at-a-time file transfer. | **Delivery adapted now; storage/cache work remains useful.** Preserve our day rollover and mode-colored segments. Do not copy upstream's “keep whichever snapshot has more points” rule, which can retain stale prior-day data. The new transfer policy also checks outstanding transfers after relaunch. |
| External location services | Upload mapped geometry plus unattached fixes; synthesize timestamps along matched paths; coordinate upload work across devices. | **Keep raw automatic uploads; adapt multi-device scheduling separately.** The mapped-route export could become an explicitly chosen export option, with provenance. Never silently change existing destinations to receive invented observations or automatically upload imported history. |
| Backup | Actor-confined export and shared daily-job claim. | **Keep our complete backup behavior.** Our fork already repaired completeness issues. A shared daily filename/claim is not enough to prove two devices have the same history. See shared work below. |
| Help, measurement formatting, platform polish | Offline topic library, Mac help, localized formatting, platform guards, icon metadata preservation, and project/signing changes. | **Adapt supporting pieces.** Help must describe our actual interface and semantics. Keep xcconfig-driven identity and current privacy rules. Icon generation metadata preservation is in the safety patch. Avoid importing generated build output, user state, or upstream agent instructions. |

## Shared background jobs: what it does and what needs changing

The source is [`CrossDeviceWorkCoordinator.swift`](https://github.com/holgerkrupp/Moves/blob/1f11daf802b2a7c0a531509a3b290425bec03a38/Moves/CrossDeviceWorkCoordinator.swift).
It is a distributed lease, not a general job scheduler. A deterministic work key
addresses a record in the user's private CloudKit database. Conditional saves
pick one owner, and another device may take over after expiration. It adds no
third-party server. Capture is not itself a leased job.

The implementation has real value: server-side conflict detection, bounded
retries, owner-token checks, expiration, and a clear choice between deferring
shared work or allowing harmless duplicate execution offline. However, checking
the callers reveals these gaps:

1. **Long jobs:** leases default to 15 minutes. A `renew` method exists, but none
   of the three production callers invokes it. A long upload can overlap another
   device after expiry. Renewal needs a bounded heartbeat, cancellation on lost
   ownership, and destination idempotency; a lease cannot promise exactly-once
   network delivery after an uncertain response.
2. **Incomplete replicas:** daily backup keys contain day and format, not the
   version/completeness of the day's data. A lagging device can mark yesterday
   complete. Another device may then accept an existing incomplete backup. A
   safe adaptation must reconcile source revisions or preserve device-specific
   backups, and must allow late-arriving history to refresh the backup.
3. **Upload identity/progress:** an upload key groups a destination into an hour
   (or a date for backfill), while completion markers are per-run timestamps and
   cursors are local. This excludes simultaneous work for a limited interval;
   it does not establish shared per-record progress or complete deduplication.
   Destination identity also needs to distinguish relevant accounts without
   exposing credentials. Never advance another device's cursor based on data it
   has not actually sent or received.
4. **Offline behavior:** external uploads defer when CloudKit cannot coordinate,
   even if the destination itself is reachable. This is a new dependency and
   could recreate the connection failures Roger wants to avoid. Single-uploader
   ownership per destination is a simpler fallback; independently recording
   devices need source-aware routing and explicit ownership transfer.
5. **No capture coupling:** GPS, local saves, local caches, and consent must keep
   working while CloudKit is unavailable. Map/exploration caches are local work,
   so every device needs its own copy; leasing them account-wide is incorrect.
6. **Schema:** direct `MovesWorkLease` records require deployment in the fork's
   own private container. Use `MovesAppIdentity`, retain one authoritative store,
   and validate both signed targets. Do not copy upstream's hardcoded container
   or assume its production schema applies to this fork.

Recommendation: include the coordination capability with multi-device support,
but start from explicit per-device recording and destination ownership. Use
leases only for truly shared side effects whose work identity and recovery are
defined. Keep deterministic inference idempotent and local caches device-local.

## Implemented broader integration

Workstream: WS4 (maps/routes), WS6 (files), WS8 (Places/Insights), and WS12
(reliability), composed into the existing iOS app. Source baseline is the reviewed
upstream tip above. This is an adaptation, not a wholesale merge of its schema or UI.

| Area | Implementation and deliberate differences |
| --- | --- |
| Durable file imports | `DurableImportQueue` owns one sequential queue for route files, Google Timeline, and Moves archives. Sources are copied while security access is held; atomic local state survives relaunch. Interrupted jobs reopen paused with Resume/Retry. Detached parsing/writing receives cancellation. iOS background time only finishes an active user import; it never schedules a recurring wake. Resume replays with deduplication; there is no destructive range replacement. Edited/imported/reviewed visits and curated moves are preserved, as are removal tombstones. Source files are never deleted. |
| Startup and iCloud | Event buffering starts before opening the one process-wide container. Upload and download times/errors are tracked separately, account errors retain priority, and actual local-only fallback is reported honestly. A store-open failure offers Retry rather than terminating or replacing history. Capture, uploads, and import workers have process-lifetime owners, independent of view identity. |
| Timeline and Places browsing | Navigation reads first/last dates with bounded queries and builds plain calendar dates, without inserting blank history. Only the current and adjacent timeline pages are mounted. Spotlight copies paged visit values and skips unchanged donations. A learned place queries only its matching visits and progressively shows additional rows. Existing map aggregates and fork corrections remain authoritative. |
| Map snapshots | Bounded memory cache and shared in-flight base-map snapshots; cancellation stops unused work. Route overlays are redrawn from current data, so edits do not reuse a stale route image. No new disk cache or background scheduler. |
| File previews | Upstream `RouteFileKit` / `RoutePreviewKit`, iOS Quick Look preview and thumbnail extensions. Identity comes from xcconfig. Thumbnails use local geometry; full previews fall back to geometry if map tiles fail. Parsers are isolated from the timeline store and bounded. The fork's richer semantic import parsers remain authoritative; replacing them would discard import behavior that the preview parser does not provide. |
| Recorded-location inspection | A read-only, paged view from a move's detail toolbar: timestamp, original coordinate, accuracy, speed, and source, with map selection. It never starts GPS or overwrites a reconstructed route. |
| Exploration and Fog of World | Upstream fine raster and archive package adapted to the existing Fog layer. Queries page original ground observations for the visible region and are cancelled on navigation; coarse display cells bound drawing at wide zoom. Photo/flight observations do not count as ground exploration. Explicit Fog import keeps undated coverage separately; it never invents dates or enters automatic uploads. Explicit export combines ground observations with imported coverage and redacts Home/Work privacy cells. Archive decoding is pull-based and cancellable. |
| Country insight | Bundled upstream Natural Earth country boundaries fill missing country codes for visit statistics offline, without changing stored visits or counting flight lines as visits. Existing city/country analytics and dates remain. No new network geocoding or administrative-region guesses. |
| Flight geometry | True spherical interpolation replaces the fork's decorative Bezier arc. Antipodes and date-line crossings are handled, including split map/snapshot strokes. Original recorded geometry and explicit route edits remain intact. No airline lookup service or invented flight metadata. |

### Deliberately retained or deferred

- **Mac browsing, multiple recording devices, and shared CloudKit work leases:**
  deferred at Roger's explicit request. No device provenance migration or shared
  upload/backup ownership is enabled in this change.
- **Compact imported-route storage:** still a separate data-format migration.
  Every existing sample, timestamp, speed, accuracy, export, and old-store reader
  is retained. No destructive compaction is required for the features above.
- **Photos:** retain the existing read-only importer and attachment model. GPS
  writing into the library remains a separate product decision.
- **Exploration:** adapt the fine raster and compatibility format, not upstream's
  entire DEBUG-only source-shard/tile/work-queue architecture. Visible-region work
  is simpler at this fork's scale and adds no always-running history scanner.
- **Flight fragments/manual evidence/passport/achievements:** retain the fork's
  current split/merge/undo tools. New flight metadata models, manual country claims,
  decorative artifacts, and a live airline provider are not prerequisites for the
  integrated geometry and offline visit statistics.
- **Watch and uploads:** retain the previously integrated delivery safeguards,
  fork day-rollover behavior, original-point upload contract, and complete backups.
  Do not adopt upstream's synthesized automatic upload geometry or point-count-only
  Watch snapshot replacement policy.

The assessment table above is the original option review. This implementation
ledger supersedes its proposed ordering and any “remain to integrate” wording for
features completed here. Deferred features remain discoverable for future work.

## Initial safety adaptations and provenance

| Adaptation | Upstream evidence | Fork-specific handling |
| --- | --- | --- |
| Duration-weighted motion | `42cc8ba9`, `503a8079`, current `LocationChange.swift` | Keep confidence, unknown fallback, and implausible long-trip rejection. No additional location or network work. |
| Preserve recorded steps | `f06f0d60` | Nil means no new evidence; explicit zero remains valid. Preserve user transport choice. |
| Foreground fix coalescing | `a4a3ebaa`, current `LocationChange.swift` | Apply 45-second cooldown and 20-second result window to existing launch/authorization requests, without adding timeline-triggered requests or timers. Skip redundant requests during continuous capture. |
| Watch transfer serialization | `354f3297`, current `WatchLocationTracker.swift` | Check outstanding system transfers after relaunch, retain failed files, back off retries, preserve existing map/day logic. |
| Nested sync errors | `06ede165`, current `SyncDiagnostics.swift` | Reuse existing status vocabulary; bounded traversal of underlying, multiple, and partial failures; prefer actionable account/quota problems. No reset or extra retries. |
| Icon metadata preservation | `354f3297`, `Scripts/generate-icon-previews.sh` | Replace only generated icon entries so platform preprocessor lines and identity metadata survive. |

## Ongoing upstream process

- Keep this fork derivative, with upstream commits and their authors available.
  There is no plan to push our product direction upstream.
- Fetch upstream, compare from the last actual integrated base, and keep a
  reviewed-tip plus per-feature ledger. A reviewed tip is not a merged tip.
- Small adapted commits should record source commit IDs and why the fork differs.
  A later real integration merge can record upstream ancestry once the decisions
  for that range are implemented or explicitly declined.
- Never resolve future conflicts by wholesale choosing one side of models,
  capture, sync, or app startup. Recheck behavioral invariants and dependencies.
- Keep parallel work isolated. Send exact validated commits to the main owner;
  do not stash, overwrite, reset, or commit their unfinished changes.
- Run the full fork suite before pushing, verify old-store compatibility on a
  copy, and exercise real devices for claims about energy, Watch delivery, and
  CloudKit. Simulator success is not physical battery/sync verification.

## Verification

Safety adaptation commit: `2f8fa55a2ddd030b9da5da493d1aa341bfc0af96`,
incorporated by the concurrent main owner as `3b62e659`.

The full simulator suite passed: **400 tests executed, 3 opt-in live Google
Takeout tests skipped, zero failures**. This run included the available large
location-log/archive fixtures and the November 9 phone-store copy. The real-store
test opened the copied history, exercised repair/reconciliation, and retained
every row. The original phone store was not modified by these tests.

Both app and Watch code compiled. Built identity values (bundle, app group,
CloudKit container, ubiquitous container, and background task IDs) were inspected.
Result bundle:
`/tmp/Moves-upstream-derived/Logs/Test/Test-Moves-2026.11.09_13-24-35-+0700.xcresult`.

The icon generator passed an isolated check for existing/missing icon sections,
preprocessor preservation, XML escaping, identity placeholders, and idempotence.
Upstream's standalone `RouteFileKit` (5 tests) and `FogOfWorldKit` (6 tests)
also passed on this Mac. Both packages are now vendored in the broader integration.

Physical battery behavior, actual Watch transfer/relaunch, and two-device CloudKit
delivery were not verified by these simulator/package tests. Device deployment
belongs to the concurrent main owner.
The original safety run does not validate the broader integration; its separate verification record follows.

## Reviewed commit range

The complete fetched range is retained here so later work can revisit a feature
without treating a postponed integration as permanently rejected. Merge commits
are included; the feature assessments above refer to the resulting source.

- [`0b095090`](https://github.com/holgerkrupp/Moves/commit/0b09509082eb46e2aa238d9815ac9836b159231e) — Add known locations and refine statistics
- [`81c78bcd`](https://github.com/holgerkrupp/Moves/commit/81c78bcdc8646515c4b798c72fb8fba5e2d4265c) — Adopt split navigation for Duo layouts
- [`8e86b65b`](https://github.com/holgerkrupp/Moves/commit/8e86b65b25025a1a5d4c0d2a08b573043c65b285) — Support multi-device timeline resolution
- [`17783e1c`](https://github.com/holgerkrupp/Moves/commit/17783e1c864c303ca0017226dc0f01cc7f0e12ed) — Use system name for multiple-device settings
- [`7ba92dc3`](https://github.com/holgerkrupp/Moves/commit/7ba92dc300bf2cf8473ba1b1c2fddd4569e51636) — Prompt for location role on additional devices
- [`ff6ba9d4`](https://github.com/holgerkrupp/Moves/commit/ff6ba9d4b2d93c0a55395db6b87cb93d71a410d4) — Use location listening setting for device roles
- [`354f3297`](https://github.com/holgerkrupp/Moves/commit/354f3297bef47a5fc0fce2940453b04b5687dc33) — Mac app
- [`b1cd71bb`](https://github.com/holgerkrupp/Moves/commit/b1cd71bb23b927561fc607f25cc218c493240316) — Add native macOS Moves timeline target
- [`ce07e44f`](https://github.com/holgerkrupp/Moves/commit/ce07e44f7292dae04535cfe801e21f945cfa6af6) — Refactor route imports into persisted queue
- [`dd4fa735`](https://github.com/holgerkrupp/Moves/commit/dd4fa735ecefcd8772c18e88a30f808427345472) — Harden route import acquisition and staging
- [`ae92c070`](https://github.com/holgerkrupp/Moves/commit/ae92c070769912a65d177e634120282ea167b753) — Move route parsing off main actor
- [`472eb7e1`](https://github.com/holgerkrupp/Moves/commit/472eb7e14d869503e7c9f0b1f02ef2f88f0915bd) — Implement native macOS location history browser
- [`1b57a55a`](https://github.com/holgerkrupp/Moves/commit/1b57a55a47f8db29c4b1edf141ffd627522afc71) — Add shared import queue progress UI
- [`c46754e3`](https://github.com/holgerkrupp/Moves/commit/c46754e37fde3eb104447a8a58ddbd5d1c791d7d) — Move route file persistence to SwiftData worker
- [`48583770`](https://github.com/holgerkrupp/Moves/commit/485837703d42d4e6ff30be6c49e74ee3c88babca) — Unify route import recovery state
- [`d41e6737`](https://github.com/holgerkrupp/Moves/commit/d41e67379710251664dc400b825ec7436b7d5952) — Route import entry points through shared coordinator
- [`8b960332`](https://github.com/holgerkrupp/Moves/commit/8b960332bf0102d3223427f5213835f63919549d) — Add Mac import library and recovery destinations
- [`0c6489dc`](https://github.com/holgerkrupp/Moves/commit/0c6489dcf63bd7197754a5677dab5fd818b4d422) — Run route imports with iOS background tasks
- [`f7674991`](https://github.com/holgerkrupp/Moves/commit/f7674991ed7356dad2e460be537496c542950816) — Add generated route import stress tests
- [`f06f0d60`](https://github.com/holgerkrupp/Moves/commit/f06f0d6085135b0ccf4823ed9ebfa381f0ae401c) — Fix walking legs after car trips
- [`e98b121f`](https://github.com/holgerkrupp/Moves/commit/e98b121f0ae8152d45a2e0405ada7f95519f4d8f) — Document movement inference limitations
- [`aab9ea49`](https://github.com/holgerkrupp/Moves/commit/aab9ea49be8f8882b167c236f88977f203ee1b44) — Refresh historical timeline presentation after sync
- [`61a1ac74`](https://github.com/holgerkrupp/Moves/commit/61a1ac74efddd15dd6462709edf38f6bbdd04b7b) — native Mac
- [`579db7e6`](https://github.com/holgerkrupp/Moves/commit/579db7e624bc15fbb4b25b132635ff105c154f12) — better Mac App
- [`2d97ec83`](https://github.com/holgerkrupp/Moves/commit/2d97ec834dbf98cb9093f3d09d7cc7e8116f6753) — even better mac
- [`2eaa53ae`](https://github.com/holgerkrupp/Moves/commit/2eaa53ae6a8bd140539d4d3fa8d79498fac5ce06) — Context menus
- [`6c5d7913`](https://github.com/holgerkrupp/Moves/commit/6c5d7913d3aba07ff97e0f4347ee288e7a1905f0) — better search
- [`00d117db`](https://github.com/holgerkrupp/Moves/commit/00d117dbdd5bf99d3a7cc88f7b8bdbaa912e31a9) — Mass importing
- [`ed645366`](https://github.com/holgerkrupp/Moves/commit/ed64536606757749157e7c1b4e70fe1ceee8b07c) — updates
- [`48b2153c`](https://github.com/holgerkrupp/Moves/commit/48b2153cd124ed22c3f1d08ce106d425c551f9fc) — Performance Boost
- [`e1f175d7`](https://github.com/holgerkrupp/Moves/commit/e1f175d78c7c95b33ebded0e699c6af582c8a666) — Checkpoint current Moves worktree
- [`8440e560`](https://github.com/holgerkrupp/Moves/commit/8440e5602a9f78ea97e1eefd96bc2c3b0c36aa6d) — Restore compact timeline map hero
- [`595d06aa`](https://github.com/holgerkrupp/Moves/commit/595d06aa2ea9dd5483b57dc0ba94e439e69e7285) — Document Fog of the World FWSS reverse-engineering findings
- [`c5715d83`](https://github.com/holgerkrupp/Moves/commit/c5715d83ed4ea7c9294d577fced71591b1300bae) — statistics
- [`0daf30b9`](https://github.com/holgerkrupp/Moves/commit/0daf30b9539e14ff9bed8afd58ecc0c8829a6032) — Fog of the world compability
- [`da42dbb3`](https://github.com/holgerkrupp/Moves/commit/da42dbb3f1953540888600fd164476f13cbff1cd) — Coordinate shared background work across devices
- [`79165efa`](https://github.com/holgerkrupp/Moves/commit/79165efa1ad1a1a6a6567686ae116e06d5d358d2) — Merge remote-tracking branch 'github/main' into Exploration
- [`7c607cd0`](https://github.com/holgerkrupp/Moves/commit/7c607cd0f818eb999c998702b63b155754cb7eb1) — Integrate debug Apple Photos location workflows
- [`b7a105e4`](https://github.com/holgerkrupp/Moves/commit/b7a105e4ed5f1548494cf6a7e5e7c454edd26d8e) — Finish resilient route import recovery
- [`392d5882`](https://github.com/holgerkrupp/Moves/commit/392d5882673ee121caae6f1082c6fa17129c026e) — Exploration
- [`1ebb17c6`](https://github.com/holgerkrupp/Moves/commit/1ebb17c69df6edb9ab554926b3bb7637612176d0) — Expose Photos integration in macOS Settings
- [`6dffa7fa`](https://github.com/holgerkrupp/Moves/commit/6dffa7fad84c1c1fc5bdfb0483560e8e2647d7c8) — Add Photos visit preview and import management
- [`20072373`](https://github.com/holgerkrupp/Moves/commit/2007237313a0856fa353fd39f8cf8636af1e39b3) — Link imported visits to Photos assets
- [`18c16129`](https://github.com/holgerkrupp/Moves/commit/18c1612988970a69e6325361fbfd5e8d828f018e) — Flights and bugfix
- [`503a8079`](https://github.com/holgerkrupp/Moves/commit/503a8079dca9bbb34f5e9a1e736aca2a43de52b7) — Bugfixes (Mapping & Sync
- [`0d97aa48`](https://github.com/holgerkrupp/Moves/commit/0d97aa48e4b2c49ec512f4931865f763ce561fcd) — Removal of mac entitlements
- [`8108f174`](https://github.com/holgerkrupp/Moves/commit/8108f174d10efe7415847185b6dce4677e3a01f5) — fix
- [`6b5cd3bc`](https://github.com/holgerkrupp/Moves/commit/6b5cd3bcae743e18d880990e5609b59c6620f829) — betterUI
- [`42cc8ba9`](https://github.com/holgerkrupp/Moves/commit/42cc8ba9e26594b5d11b14ff4d7857180d3f908d) — Regular palces editor in iOS
- [`3d43c2ac`](https://github.com/holgerkrupp/Moves/commit/3d43c2ac9d9d55a4887f9682f36ae3b3f4f1b412) — 2026.23
- [`01bec061`](https://github.com/holgerkrupp/Moves/commit/01bec061404b966ad7122360383f3d91c9fd8b28) — 2026.23
- [`1c497242`](https://github.com/holgerkrupp/Moves/commit/1c4972426d1cd28e2a2535d12e138a40affd7333) — Move route display preference from Tracking to Appearance
- [`a83ab122`](https://github.com/holgerkrupp/Moves/commit/a83ab122f34277198d8fc266bf173765cab6413c) — Add bounded raw OS fix selection for timeline
- [`e7a844f5`](https://github.com/holgerkrupp/Moves/commit/e7a844f52124eabcd4f6a26328e8e4675928feea) — Load raw OS fix timeline rows with display-mode-aware caching
- [`31b5c656`](https://github.com/holgerkrupp/Moves/commit/31b5c65675fa9ff6a7501686844edb31de2767a5) — Render raw OS fix rows with source accuracy and map selection
- [`97379e59`](https://github.com/holgerkrupp/Moves/commit/97379e5922ca37cc7f2c56d15cb0454819907a19) — Highlight selected raw fixes on map and guard stale presentation tasks
- [`d7a60834`](https://github.com/holgerkrupp/Moves/commit/d7a608349791d7ccb30ddb343d059069eebff457) — Test raw OS fix chronology provenance and timeline row metadata
- [`b0030ca8`](https://github.com/holgerkrupp/Moves/commit/b0030ca8163cdae4daad121c01fbf397d2481cdc) — Clear stale timeline rows immediately when switching display mode
- [`5fb1c9c9`](https://github.com/holgerkrupp/Moves/commit/5fb1c9c93539c8dccc682fdd48588da31bd86610) — Show exact fix time in raw timeline metadata
- [`e79ffdc3`](https://github.com/holgerkrupp/Moves/commit/e79ffdc343a5ea97c16bd8dbd1292d49b1af9df7) — Merge pull request #161 from holgerkrupp/fix/raw-os-fixes-timeline-and-appearance
- [`bc32c47d`](https://github.com/holgerkrupp/Moves/commit/bc32c47d6509afb0971391e18c2d9953707157e6) — Implement visit history, Regular Places, and timeline performance (#174)
- [`a4a3ebaa`](https://github.com/holgerkrupp/Moves/commit/a4a3ebaa0a89c1a7a5c203b575fff891d3525a5a) — Preserve recovered Exploration and timeline work
- [`1ddb741f`](https://github.com/holgerkrupp/Moves/commit/1ddb741faa7522000b20199e5c399e1a1f0efb34) — Show timeline presentation loading and failures
- [`a95243eb`](https://github.com/holgerkrupp/Moves/commit/a95243eb827b80c203b15bd8f33aec9e499a2177) — Refresh timeline after CloudKit imports
- [`0d1e27b6`](https://github.com/holgerkrupp/Moves/commit/0d1e27b6489f45daccaeb67199a6c8f5b9f91a64) — Show mapped move routes with transport colors
- [`9a37d8b8`](https://github.com/holgerkrupp/Moves/commit/9a37d8b819a11635c0747e78cf17a0bf48b528da) — Restore reconstructed timeline move geometry
- [`2ba7bc36`](https://github.com/holgerkrupp/Moves/commit/2ba7bc369ebd9574dbd3b7c0a6a5876014d50a43) — Fix empty route fallback in timeline map
- [`c960746f`](https://github.com/holgerkrupp/Moves/commit/c960746f9374434923123cb6d29fe6ce002b04a6) — Add move mapping guide and improve route actions
- [`c1ee41a0`](https://github.com/holgerkrupp/Moves/commit/c1ee41a0e32479476f7b6f505cc961c911d63a4e) — Improve startup readiness instrumentation (#176)
- [`2dcc55fd`](https://github.com/holgerkrupp/Moves/commit/2dcc55fd71fed63ee9fda75bd3ca05648b93ff11) — Improve progressive timeline presentation #178
- [`28d8cf25`](https://github.com/holgerkrupp/Moves/commit/28d8cf25c723580b9e18cbc8cb7269b707d34a18) — Improve scalable History Map loading (#180)
- [`38b26981`](https://github.com/holgerkrupp/Moves/commit/38b26981d994dc0326794adafbcb675022713665) — Make timeline day navigation asynchronous (#177)
- [`0d1b8297`](https://github.com/holgerkrupp/Moves/commit/0d1b8297cf791c7ee75e6b0c91b83ce5564f078e) — Improve collapsed day map caching (#179)
- [`5bba77cc`](https://github.com/holgerkrupp/Moves/commit/5bba77cc833223f5f4e2a83de5e0523d056019ff) — Document performance validation procedure
- [`6045994d`](https://github.com/holgerkrupp/Moves/commit/6045994d3cdff4a17b33228aaca001404aeb2fa9) — Guard timeline day lookups against stale requests (#177)
- [`3bfbeda7`](https://github.com/holgerkrupp/Moves/commit/3bfbeda7c878e09112feb2bce0d4c6a39f06a8ec) — Add timeline and map scalability regression tests for #178 #180
- [`ea4975c1`](https://github.com/holgerkrupp/Moves/commit/ea4975c109e9c524dbec5c3b13ba21312efda1ec) — Integrate timeline and map performance work (#176-#180)
- [`3c462084`](https://github.com/holgerkrupp/Moves/commit/3c462084d765b2a08066a2bccc076a4c4b72f591) — Merge pull request #181 from holgerkrupp/perf/integration-176-180
- [`101545c4`](https://github.com/holgerkrupp/Moves/commit/101545c4db0583612f1a8cc4380fc92caeebb502) — Start timeline street matching on first load
- [`e15822b8`](https://github.com/holgerkrupp/Moves/commit/e15822b8b3a1bd727b82186045f3bfae1ae251e4) — Merge pull request #182 from holgerkrupp/fix/timeline-first-load-route-matching
- [`22c9c756`](https://github.com/holgerkrupp/Moves/commit/22c9c7564c99a2386a2bf17558bc0a171b188d18) — help
- [`64e4da82`](https://github.com/holgerkrupp/Moves/commit/64e4da823d69e784a9e552890f48288ab72bf5a3) — Settings Crash fix
- [`06ede165`](https://github.com/holgerkrupp/Moves/commit/06ede1657f4ae79da211272006248f56ae0e69d2) — Improve CloudKit sync diagnostics and deferral handling
- [`409485ee`](https://github.com/holgerkrupp/Moves/commit/409485eecc96e6fcee0f76c4b9466595360ec142) — Prioritize and resume Exploration protection migration
- [`6db01871`](https://github.com/holgerkrupp/Moves/commit/6db01871c0a063947e618386db393cb76a491724) — Separate Exploration run diagnostics and enforce deadlines
- [`2ec8fde9`](https://github.com/holgerkrupp/Moves/commit/2ec8fde9689d2368a2126c0120497209e4bb350d) — Resume derived preparation work fairly across deadlines
- [`6815435d`](https://github.com/holgerkrupp/Moves/commit/6815435d87e89bd1f5932e764005a3260ab8d44f) — Fix incremental Exploration render hierarchy
- [`0673b0e6`](https://github.com/holgerkrupp/Moves/commit/0673b0e6d8560a239b3f7cb476671a1d8c8d2796) — Anchor Exploration fog to MapKit tiles
- [`123e216f`](https://github.com/holgerkrupp/Moves/commit/123e216f096d3abbdb0d8bafdbf146441366027b) — Smooth Exploration fog mask rendering
- [`80e9e6c0`](https://github.com/holgerkrupp/Moves/commit/80e9e6c0ac764f29fc4a004da894fbaad59928ec) — Merge pull request #191 from holgerkrupp/codex/cloudkit-sync-reliability
- [`65396e3d`](https://github.com/holgerkrupp/Moves/commit/65396e3d14f49f9db33c91fce650b1797bb8b8d3) — Merge pull request #192 from holgerkrupp/codex/exploration-prep-recovery
- [`5d01a7e8`](https://github.com/holgerkrupp/Moves/commit/5d01a7e81389a85e61c17178da4cf1204267fce2) — Backfill visible Exploration render tiles
- [`507c13ac`](https://github.com/holgerkrupp/Moves/commit/507c13acd222fa695d93c69676c12d7e9e1861ab) — Merge pull request #193 from holgerkrupp/codex/exploration-visible-backfill
- [`1f11daf8`](https://github.com/holgerkrupp/Moves/commit/1f11daf802b2a7c0a531509a3b290425bec03a38) — docs: standardize AGENTS.md and add pragmatic solo-developer policy
