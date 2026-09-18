import Foundation

/// Bar heights for the stacked daily-requests chart.
///
/// A failure that is one request in eight hundred is a sub-pixel sliver: the
/// summary tile said 失败 4 while the chart showed a solid blue wall, which is
/// the opposite of what a chart is for. Non-success segments are therefore
/// drawn at a floor, and the space is taken back out of the success segment
/// beneath them, so each bar's total height still equals that day's request
/// count exactly — the floor moves the boundary inside the bar, it never
/// inflates the bar.
///
/// The floor is a share of the tallest day rather than of each day's own total,
/// because the y-axis is shared: a share of the axis is what "visible" means,
/// and a quiet day's single failure should not draw taller than a busy day's.
enum StatsChartLayout {
    /// Fraction of the axis a non-empty segment is guaranteed. At the chart's
    /// 200pt height this is ~5pt — a legible sliver, and small enough that the
    /// success segment it is borrowed from stays visually unchanged.
    static let minimumSegmentShare = 0.025

    struct Segment: Equatable {
        let status: String
        /// The real number, for anything that reports counts.
        let count: Int
        /// What the bar draws.
        let plotted: Double
    }

    /// `segments` is one day's counts. `axisMax` is the tallest day in the
    /// chart, which sets the scale everything is measured against.
    static func plotted(
        segments: [(status: String, count: Int)],
        axisMax: Int,
        successLabel: String
    ) -> [Segment] {
        let floor = Double(axisMax) * minimumSegmentShare
        var borrowed = 0.0
        var raised: [String: Double] = [:]
        for segment in segments where segment.status != successLabel && segment.count > 0 {
            let plotted = Swift.max(Double(segment.count), floor)
            raised[segment.status] = plotted
            borrowed += plotted - Double(segment.count)
        }
        return segments.map { segment in
            if let plotted = raised[segment.status] {
                return Segment(status: segment.status, count: segment.count, plotted: plotted)
            }
            guard segment.status == successLabel else {
                return Segment(status: segment.status, count: segment.count, plotted: Double(segment.count))
            }
            // Never below zero: a day that is *only* failures has nothing to
            // lend, and the bar is then a hair taller than its count rather
            // than the segment being invisible.
            return Segment(
                status: segment.status,
                count: segment.count,
                plotted: Swift.max(0, Double(segment.count) - borrowed)
            )
        }
    }
}
