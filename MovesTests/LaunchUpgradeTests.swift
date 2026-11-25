import CoreLocation
import SwiftData
import XCTest
@testable import Moves

/// The one-time launch upgrade: which steps run for a stored version, that it finishes and
/// says so on the waiting screen, and that the faster duplicate-stop pass still merges.
@MainActor
final class LaunchUpgradeTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        let schema = Schema(MovesTimelineSchema.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: [configuration])
        context = ModelContext(container)
        context.autosaveEnabled = false
        suiteName = "LaunchUpgradeTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        context = nil
        container = nil
    }

    func testPhoneAtVersionThreeRunsOnlyTheNewerStepsAndNoTripRebuild() {
        let plan = TimelineSchemaUpgrader.steps(from: 3)

        XCTAssertEqual(plan.map(\.version), [4, 4, 5, 5, 6, 7, 8, 9, 9])
        XCTAssertFalse(plan.contains { if case .longTrips = $0.work { true } else { false } })
        XCTAssertTrue(TimelineSchemaUpgrader.steps(from: TimelineSchemaUpgrader.currentVersion).isEmpty)
    }

    func testFreshInstallRebuildsLongTripsLastAfterOriginsAndAnswersAreSettled() throws {
        let plan = TimelineSchemaUpgrader.steps(from: 0)

        XCTAssertEqual(plan.first?.version, 1)
        let last = try XCTUnwrap(plan.last)
        guard case .longTrips = last.work else { return XCTFail("The trip rebuild must run last") }
        XCTAssertTrue(plan.allSatisfy { !$0.title.isEmpty })
    }

    func testUpgradeFinishesRecordsTheCurrentVersionAndClearsTheWaitingLine() async throws {
        insertStay(arrivingAfter: 0, label: "Corner shop")
        insertStay(arrivingAfter: 3 * 3_600, north: 3_000, label: "Corner shop")
        try context.save()
        defaults.set(3, forKey: TimelineSchemaUpgrader.userDefaultsKey)

        TimelineSchemaUpgrader.runIfNeeded(container: container, defaults: defaults)
        XCTAssertTrue(TimelineSchemaUpgrader.isRunning)
        await TimelineSchemaUpgrader.waitUntilFinished()

        XCTAssertEqual(defaults.integer(forKey: TimelineSchemaUpgrader.userDefaultsKey), TimelineSchemaUpgrader.currentVersion)
        XCTAssertEqual(TimelineUpgradeProgress.shared.fractionCompleted, 1)
        XCTAssertNil(TimelineUpgradeProgress.shared.stepTitle)
        XCTAssertEqual(try ModelContext(container).fetchCount(FetchDescriptor<VisitPlace>.live()), 2)
    }

    func testDuplicateStopsStillMergeWhileLoneStopsAreLeftAlone() throws {
        // The same arrival reported twice, a few metres apart.
        insertStay(arrivingAfter: 0, departingAfter: 3_600, north: 0)
        insertStay(arrivingAfter: 0.5, departingAfter: 3_600, north: 20)
        // Arrivals at the edge of the three-minute window, with matching departures.
        insertStay(arrivingAfter: 10_000, departingAfter: 13_000, north: 2_000)
        insertStay(arrivingAfter: 10_180, departingAfter: 13_100, north: 2_040)
        // On their own.
        insertStay(arrivingAfter: 20_000, departingAfter: 21_000, north: 4_000)
        insertStay(arrivingAfter: 30_000, departingAfter: 31_000, north: 9_000)
        try context.save()

        try SwiftDataTimelineRepository(modelContext: context).repairDuplicateStays()

        let arrivals = try context.fetch(
            FetchDescriptor<VisitPlace>.live(sortBy: [SortDescriptor(\VisitPlace.arrivalDate)])
        ).map { $0.arrivalDate.timeIntervalSince(start).rounded() }
        XCTAssertEqual(arrivals.count, 4)
        XCTAssertEqual(Array(arrivals.suffix(2)), [20_000, 30_000])
    }

    // MARK: - Helpers

    @discardableResult
    private func insertStay(
        arrivingAfter arrival: TimeInterval,
        departingAfter departure: TimeInterval? = nil,
        north meters: Double = 0,
        label: String? = nil
    ) -> VisitPlace {
        let stay = VisitPlace(
            arrivalDate: start.addingTimeInterval(arrival),
            departureDate: start.addingTimeInterval(departure ?? arrival + 1_800),
            latitude: 10 + meters / 111_000,
            longitude: 100,
            horizontalAccuracy: 20,
            autoLabel: label
        )
        context.insert(stay)
        stay.dayTimeline = day(containing: stay.arrivalDate)
        return stay
    }

    /// A live stay is always on a day; reuse the one already inserted for this date.
    private func day(containing date: Date) -> DayTimeline {
        let key = DayTimeline.makeDayKey(for: date)
        if let existing = try? context.fetch(FetchDescriptor<DayTimeline>(predicate: #Predicate { $0.dayKey == key })).first {
            return existing
        }
        let day = DayTimeline(dayStart: date)
        context.insert(day)
        return day
    }
}
