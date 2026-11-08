//
//  LivePreviewChart.swift
//  Iphone_motion
//
//  Last ~10 s of the iPhone's orientation (decimated), for checking the sensor before recording.
//

import Charts
import SwiftUI

struct LivePreviewChart: View {
    let samples: [PreviewSample]

    var body: some View {
        let latest = samples.last?.t ?? 0
        Chart {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                LineMark(x: .value("Time", sample.t - latest), y: .value("Angle", sample.roll), series: .value("Angle", "Roll"))
                    .foregroundStyle(by: .value("Angle", "Roll"))
                LineMark(x: .value("Time", sample.t - latest), y: .value("Angle", sample.pitch), series: .value("Angle", "Pitch"))
                    .foregroundStyle(by: .value("Angle", "Pitch"))
                LineMark(x: .value("Time", sample.t - latest), y: .value("Angle", sample.yaw), series: .value("Angle", "Yaw"))
                    .foregroundStyle(by: .value("Angle", "Yaw"))
            }
        }
        .chartForegroundStyleScale(["Roll": Color.red, "Pitch": Color.green, "Yaw": Color.blue])
        .chartXScale(domain: -10...0)
        .chartYScale(domain: -180...180)
        .chartYAxis {
            AxisMarks(values: [-180, -90, 0, 90, 180])
        }
        .chartXAxisLabel("seconds")
        .chartYAxisLabel("degrees")
        .chartLegend(position: .top, alignment: .leading)
        .overlay {
            if samples.isEmpty {
                Text("Waiting for motion data…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
