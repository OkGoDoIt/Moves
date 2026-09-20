import Charts
import SwiftUI

/// 7×24 arrival heatmap for a learned place.
struct OccupancyChartView: View {
    let grid: OccupancyGrid
    var calendar: Calendar = .autoupdatingCurrent

    private var cells: [OccupancyChartCell] {
        OccupancyChartCell.cells(from: grid, calendar: calendar)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "When you’re usually there"))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            if grid.hasData {
                Chart(cells) { cell in
                    RectangleMark(
                        x: .value(String(localized: "Hour"), cell.hour),
                        y: .value(String(localized: "Day"), cell.row)
                    )
                    .foregroundStyle(color(for: cell.count))
                }
                .chartXScale(domain: -0.5...23.5)
                .chartYScale(domain: -0.5...6.5)
                .chartXAxis {
                    AxisMarks(values: [0, 6, 12, 18]) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let hour = value.as(Int.self) {
                                Text(hourLabel(hour))
                                    .font(.system(size: 10, weight: .medium, design: .rounded))
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(values: Array(0..<7)) { value in
                        AxisValueLabel {
                            if let plotY = value.as(Int.self) {
                                let displayRow = 6 - plotY
                                if weekdayLabels.indices.contains(displayRow) {
                                    Text(weekdayLabels[displayRow])
                                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                                }
                            }
                        }
                    }
                }
                .chartLegend(.hidden)
                .frame(height: 168)
                .accessibilityLabel(grid.peakSummary)
            } else {
                Text(String(localized: "Visit this place a few more times to see a weekly pattern."))
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var weekdayLabels: [String] {
        OccupancyChartCell.orderedWeekdaySymbols(calendar: calendar)
    }

    private func color(for count: Int) -> Color {
        guard grid.maximum > 0, count > 0 else {
            return Color(uiColor: .tertiarySystemFill)
        }
        let fraction = Double(count) / Double(grid.maximum)
        return MovesPalette.place.opacity(0.18 + (0.82 * fraction))
    }

    private func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        let date = calendar.date(from: components) ?? Date()
        return date.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated)))
    }
}

/// One cell in the occupancy chart, already rotated to the locale’s first weekday.
struct OccupancyChartCell: Identifiable, Equatable {
    var id: String { "\(row)-\(hour)" }
    /// Plot Y: 6 is the locale’s first weekday (top), 0 is the last (bottom).
    var row: Int
    var hour: Int
    var count: Int

    static func orderedWeekdaySymbols(calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        guard symbols.count == 7 else { return symbols }
        return Array(symbols[first...]) + Array(symbols[..<first])
    }

    static func cells(from grid: OccupancyGrid, calendar: Calendar) -> [OccupancyChartCell] {
        let first = calendar.firstWeekday - 1
        var result: [OccupancyChartCell] = []
        result.reserveCapacity(7 * 24)
        for displayRow in 0..<7 {
            let weekdayIndex = (first + displayRow) % 7
            for hour in 0..<24 {
                result.append(
                    OccupancyChartCell(
                        row: 6 - displayRow,
                        hour: hour,
                        count: grid.counts[weekdayIndex][hour]
                    )
                )
            }
        }
        return result
    }
}
