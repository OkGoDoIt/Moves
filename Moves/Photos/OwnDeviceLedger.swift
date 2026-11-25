import Foundation

/// One item on a phone's camera roll, as far as its file name and dates tell.
///
/// An iPhone names what it captures from one running counter: `IMG_4317`, `IMG_4318`,
/// photos, videos, and screenshots alike. Two phones are two counters, even when they are
/// the same model, so the counter says which device made a file.
struct CameraRollEntry: Sendable, Equatable {
    /// When the item entered the library. A phone numbers its files in this order.
    var addedAt: Date
    /// The counter value in the file name, 0 through 9999.
    var number: Int
    var isScreenshot: Bool

    /// The counter in a camera file name such as `IMG_4317.HEIC`, or `nil` for any other name.
    static func number(inFileName name: String?) -> Int? {
        guard let name, name.count >= 9, name.hasPrefix("IMG_") else { return nil }
        let digits = name.dropFirst(4).prefix(4)
        guard digits.count == 4, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber),
              name.dropFirst(8).first == "."
        else { return nil }
        return Int(digits)
    }
}

/// Works out which camera-roll items came from the library owner's own phone.
///
/// PhotoKit does not say which device took a photo or whether it came through an iCloud
/// Shared Library. The file counter does: the library is split into runs that each count
/// upward the way one device does, and a run belongs to the owner when it carries the
/// owner's screenshots, which are numbered from the same counter and are not shared. A run
/// without screenshots still belongs to the owner when it picks up where the owner's last
/// run stopped and the owner's phone was not busy on another counter meanwhile. Anything
/// else running alongside is another device.
///
/// The counter carries over when a phone is replaced, so the owner's run continues across
/// phones without a list of models.
struct OwnDeviceLedger: Sendable {
    struct Configuration: Sendable {
        /// The next file on a device is at most this far ahead: deleted shots leave holes.
        var adjacentJump = 30.0
        /// A device that was quiet may have moved this much further per day.
        var jumpPerDay = 40.0
        /// Files saved a moment out of order still belong to the run.
        var backwardTolerance = 5
        /// A run that has been quiet this long is ended; the device starts a new one.
        var runLifetime: TimeInterval = 2 * 24 * 60 * 60
        /// Screenshots a run needs before it is taken for the owner's.
        var minimumScreenshots = 2
        /// How far past the owner's last run a screenshot-free run may begin and still continue it.
        var continuationJump = 600.0
        var continuationGap: TimeInterval = 30 * 24 * 60 * 60
        /// Share of a run's length the owner's other runs may overlap before it is another device.
        var concurrencyShare = 0.05

        init() {}
    }

    private let own: Set<UInt64>
    /// Camera-roll items on the owner's runs, and on anyone else's.
    let ownItemCount: Int
    let otherItemCount: Int

    /// No file names were available, so the ledger cannot tell devices apart.
    var isEmpty: Bool { ownItemCount + otherItemCount == 0 }

    func contains(addedAt: Date, number: Int) -> Bool {
        own.contains(Self.key(addedAt: addedAt, number: number))
    }

    init(entries: [CameraRollEntry], configuration: Configuration = Configuration()) {
        let items = entries.sorted { ($0.addedAt, $0.number) < ($1.addedAt, $1.number) }
        let times = items.map(\.addedAt.timeIntervalSinceReferenceDate)

        var timesByNumber: [Int: [TimeInterval]] = [:]
        for (index, item) in items.enumerated() {
            timesByNumber[item.number, default: []].append(times[index])
        }

        // A jump over numbers that turn up later is not one device skipping ahead: it is a
        // second device whose counter happens to sit just in front of the first.
        func isFilledLater(from: Int, to: Int, after time: TimeInterval) -> Bool {
            var number = (from + 1) % 10_000
            while number != to {
                if let seen = timesByNumber[number] {
                    let next = seen.partitioningIndex { $0 > time + 60 }
                    if next < seen.count, seen[next] <= time + configuration.runLifetime {
                        return true
                    }
                }
                number = (number + 1) % 10_000
            }
            return false
        }

        var runs: [Run] = []
        var live: [Int] = []
        var runOfItem = [Int](repeating: 0, count: items.count)

        for (index, item) in items.enumerated() {
            let time = times[index]
            var best: Int?
            var bestDistance = Int.max
            for runIndex in live {
                let run = runs[runIndex]
                let jump = Self.forward(from: run.head, to: item.number)
                let quietDays = (time - run.end) / 86_400
                guard jump >= -configuration.backwardTolerance,
                      Double(jump) <= configuration.adjacentJump + configuration.jumpPerDay * quietDays
                else { continue }
                if jump > 1, isFilledLater(from: run.head, to: item.number, after: time) { continue }
                if abs(jump) < bestDistance {
                    best = runIndex
                    bestDistance = abs(jump)
                }
            }

            let runIndex: Int
            if let best {
                runIndex = best
            } else {
                runs.append(Run(first: item.number, head: item.number, start: time, end: time))
                runIndex = runs.count - 1
                live.append(runIndex)
            }
            if Self.forward(from: runs[runIndex].head, to: item.number) > 0 {
                runs[runIndex].head = item.number
            }
            runs[runIndex].end = time
            runs[runIndex].count += 1
            if item.isScreenshot {
                runs[runIndex].screenshots += 1
            }
            runOfItem[index] = runIndex
            live.removeAll { time - runs[$0].end > configuration.runLifetime }
        }

        for index in runs.indices {
            runs[index].isOwn = runs[index].screenshots >= configuration.minimumScreenshots
        }

        // The owner has one phone. A run that fills a pause in the owner's runs and counts on
        // from where they stopped is that phone; a run alongside them is not.
        let order = runs.indices.sorted { runs[$0].start < runs[$1].start }
        for _ in 0..<6 {
            let ownRuns = runs.indices.filter { runs[$0].isOwn }
            let ownTimes = items.indices.filter { runs[runOfItem[$0]].isOwn }.map { times[$0] }
            var changed = false
            for index in order where !runs[index].isOwn {
                let run = runs[index]
                let alongside = ownTimes.partitioningIndex { $0 >= run.end }
                    - ownTimes.partitioningIndex { $0 > run.start }
                guard Double(alongside) <= configuration.concurrencyShare * Double(run.count) + 2 else { continue }
                guard let previous = ownRuns
                    .filter({ runs[$0].end <= run.start + 60 })
                    .max(by: { runs[$0].end < runs[$1].end })
                else { continue }
                let gap = run.start - runs[previous].end
                let jump = Double(Self.forward(from: runs[previous].head, to: run.first))
                if gap <= configuration.continuationGap,
                   jump > 0,
                   jump <= configuration.continuationJump + configuration.jumpPerDay * gap / 86_400 {
                    runs[index].isOwn = true
                    changed = true
                }
            }
            if !changed { break }
        }

        var own = Set<UInt64>()
        var ownCount = 0
        for (index, item) in items.enumerated() where runs[runOfItem[index]].isOwn {
            own.insert(Self.key(addedAt: item.addedAt, number: item.number))
            ownCount += 1
        }
        self.own = own
        ownItemCount = ownCount
        otherItemCount = items.count - ownCount
    }

    private struct Run {
        var first: Int
        var head: Int
        var start: TimeInterval
        var end: TimeInterval
        var count = 0
        var screenshots = 0
        var isOwn = false
    }

    /// How far `to` is ahead of `from` on a counter that wraps at 10,000; negative when behind.
    private static func forward(from: Int, to: Int) -> Int {
        let distance = ((to - from) % 10_000 + 10_000) % 10_000
        return distance > 5_000 ? distance - 10_000 : distance
    }

    private static func key(addedAt: Date, number: Int) -> UInt64 {
        let milliseconds = Int64((addedAt.timeIntervalSinceReferenceDate * 1_000).rounded())
        return UInt64(bitPattern: milliseconds) &* 10_000 &+ UInt64(number)
    }
}

private extension Array {
    /// Index of the first element for which `predicate` is true, in an array where every
    /// element after that one is true as well.
    func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) / 2
            if predicate(self[middle]) {
                high = middle
            } else {
                low = middle + 1
            }
        }
        return low
    }
}

/// Which camera models the owner's phone has been, learned from the photos themselves.
///
/// The model is in a photo's file, not in PhotoKit, so it is read only from originals that
/// are already on the phone. It labels the owner's phones over the years, and it catches
/// the rare photo from another device that the counter let through: the owner's phone
/// changes model once and stays changed, while a stray photo is one model among many of
/// another.
struct OwnCameraRoster: Codable, Equatable, Sendable {
    struct Period: Equatable, Sendable {
        var model: String
        var from: Date
        var through: Date
    }

    /// Photos read per camera model, by month ("2026-11").
    private(set) var months: [String: [String: Int]] = [:]
    /// Models of the newest photos accepted from the owner's phone, oldest first.
    private(set) var recent: [String] = []

    private static let recentLimit = 12
    /// A month needs this many readings before a rare model in it is doubted.
    private static let minimumMonthReadings = 10
    private static let strayShare = 0.1
    /// This many photos in a row from a new model mean the phone was replaced.
    private static let replacementRun = 3

    mutating func record(model: String, capturedAt: Date) {
        months[Self.monthKey(capturedAt), default: [:]][model, default: 0] += 1
    }

    /// A model that is rare in the month it was taken, in a month the owner's phone is known.
    func isStray(model: String, capturedAt: Date) -> Bool {
        guard let counts = months[Self.monthKey(capturedAt)] else { return false }
        let total = counts.values.reduce(0, +)
        guard total >= Self.minimumMonthReadings else { return false }
        return Double(counts[model] ?? 0) < Self.strayShare * Double(total)
    }

    /// Splits new photos, oldest first, into the ones the owner's current phone took and
    /// the ones to look at again later. A new model waits until it has taken a few photos
    /// in a row, which a replacement phone does within its first day.
    mutating func acceptNew(_ photos: [(id: String, model: String?, capturedAt: Date)]) -> Set<String> {
        let models = photos.compactMap(\.model)
        let known = Self.mostCommon(in: recent)
        let latest = (recent + models).suffix(Self.replacementRun)
        let replacement = latest.count == Self.replacementRun && Set(latest).count == 1 ? latest.first : nil

        var accepted = Set<String>()
        for photo in photos {
            guard let model = photo.model else {
                // The file could not be read. The counter already says it is the owner's.
                accepted.insert(photo.id)
                continue
            }
            guard known == nil || model == known || model == replacement else { continue }
            accepted.insert(photo.id)
            record(model: model, capturedAt: photo.capturedAt)
            recent.append(model)
        }
        recent = Array(recent.suffix(Self.recentLimit))
        return accepted
    }

    /// The owner's phones in order, each with the months it was the main camera.
    func periods(calendar: Calendar = .current) -> [Period] {
        var periods: [Period] = []
        for key in months.keys.sorted() {
            guard let counts = months[key],
                  let model = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key,
                  let month = Self.monthStart(key, calendar: calendar),
                  let end = calendar.date(byAdding: DateComponents(month: 1, second: -1), to: month)
            else { continue }
            if let last = periods.indices.last, periods[last].model == model {
                periods[last].through = end
            } else {
                periods.append(Period(model: model, from: month, through: end))
            }
        }
        return periods
    }

    private static func mostCommon(in models: [String]) -> String? {
        Dictionary(grouping: models, by: { $0 })
            .max { ($0.value.count, $1.key) < ($1.value.count, $0.key) }?
            .key
    }

    private static func monthKey(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    private static func monthStart(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: 1))
    }
}

/// Keeps the roster with the import's progress, outside the timeline store.
struct OwnCameraRosterStore {
    static let key = "photos.ownCameraRoster"
    var defaults: UserDefaults = .standard

    func load() -> OwnCameraRoster {
        guard let data = defaults.data(forKey: Self.key),
              let roster = try? JSONDecoder().decode(OwnCameraRoster.self, from: data)
        else { return OwnCameraRoster() }
        return roster
    }

    func save(_ roster: OwnCameraRoster) {
        guard let data = try? JSONEncoder().encode(roster) else { return }
        defaults.set(data, forKey: Self.key)
    }
}
