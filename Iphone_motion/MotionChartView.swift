//
//  MotionChartView.swift
//  Iphone_motion
//
//  Created by Nicolas Van Vlasselaer on 18/06/2024.
//

import SwiftUI
import Charts

struct MotionChartView: View {
    var data: [MotionDataPoint]

    var body: some View {
        VStack {
            // Pitch Chart
            Chart(data) { point in
                LineMark(x: .value("Time", point.time), y: .value("Pitch", point.pitch))
                    .foregroundStyle(.red)
                    .interpolationMethod(.catmullRom)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .second)) { _ in
                    AxisGridLine()
                }
            }
            .chartYAxis {
                AxisMarks()
            }
            //.padding()
            .frame(height: 100)
            .overlay(Text("Pitch").font(.headline).padding(), alignment: .topLeading)

            // Roll Chart
            Chart(data) { point in
                LineMark(x: .value("Time", point.time), y: .value("Roll", point.roll))
                    .foregroundStyle(.green)
                    .interpolationMethod(.catmullRom)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .second)) { _ in
                        AxisGridLine()
                }
            }
            .chartYAxis {
                AxisMarks()
            }
            //.padding()
            .frame(height: 100)
            .overlay(Text("Roll").font(.headline).padding(), alignment: .topLeading)

            // Yaw Chart
            Chart(data) { point in
                LineMark(x: .value("Time", point.time), y: .value("Yaw", point.yaw))
                    .foregroundStyle(.blue)
                    .interpolationMethod(.catmullRom)
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .second)) { _ in
                        AxisGridLine()
                }
            }
            .chartYAxis {
                AxisMarks()
            }
            //.padding()
            .frame(height: 100)
            .overlay(Text("Yaw").font(.headline).padding(), alignment: .topLeading)
        }
    }
}
