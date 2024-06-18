//
//  MotionDataPoint.swift
//  Iphone_motion
//
//  Created by Nicolas Van Vlasselaer on 18/06/2024.
//

import Foundation

struct MotionDataPoint: Identifiable {
    let id = UUID()
    let time: Date
    let pitch: Double
    let roll: Double
    let yaw: Double
}
