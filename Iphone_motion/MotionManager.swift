//
//  MotionManager.swift
//  Iphone_motion
//
//  Created by Nicolas Van Vlasselaer on 18/06/2024.
//

import SwiftUI
import CoreMotion
import UIKit

class MotionManager: ObservableObject {
    @Published var pitch: Double = 0.0
    @Published var roll: Double = 0.0
    @Published var yaw: Double = 0.0
    
    @Published var quaternion: (w: Double, x: Double, y: Double, z: Double) = (0, 0, 0, 0)
    
    @Published var isRecording = false
    @Published var isUpdating = true
    
    @Published var motionDataPoints: [MotionDataPoint] = []
    @Published var activityViewControllerPresented = false
    @Published var activityItems: [Any] = []
    
    private var motion = CMMotionManager()
    private var quaternionData: [(w: Double, x: Double, y: Double, z: Double)] = []
    
    init() {
        startAttitudeUpdates()
    }
    
    func startAttitudeUpdates() {
        motion.deviceMotionUpdateInterval = 0.05
        if motion.isDeviceMotionAvailable {
            motion.startDeviceMotionUpdates(to: OperationQueue.main) { (data, error) in
                guard let attitudeData = data, error == nil else {
                    return
                }
                self.pitch = self.radiansToDegrees(radians: attitudeData.attitude.pitch)
                self.roll = self.radiansToDegrees(radians: attitudeData.attitude.roll)
                self.yaw = self.radiansToDegrees(radians: attitudeData.attitude.yaw)
                
                self.quaternion = (attitudeData.attitude.quaternion.w,
                                   attitudeData.attitude.quaternion.x,
                                   attitudeData.attitude.quaternion.y,
                                   attitudeData.attitude.quaternion.z)
                
                if self.isRecording {
                    let quaternion = attitudeData.attitude.quaternion
                    self.quaternionData.append((quaternion.w, quaternion.x, quaternion.y, quaternion.z))
                }
                
                let timeStamp = Date()
                let motionDataPoint = MotionDataPoint(time: timeStamp, pitch: self.pitch, roll: self.roll, yaw: self.yaw)
                
                self.motionDataPoints.append(motionDataPoint)
            }
        }
    }
    
    func radiansToDegrees(radians: Double) -> Double {
        return radians * 180 / .pi
    }
    
    func resetData() {
        quaternionData.removeAll()
        motionDataPoints.removeAll()
        
        pitch = 0.0
        roll = 0.0
        yaw = 0.0
        quaternion = (0, 0, 0, 0)
    }
    
    func toggleDataUpdates() {
        isUpdating.toggle()
        if isUpdating {
            startAttitudeUpdates()
        } else {
            motion.stopDeviceMotionUpdates()
        }
    }
    
    func toggleRecording() {
        isRecording.toggle()
        if !isRecording {
            saveQuaternionData()
        }
    }
    
    func saveQuaternionData() {
        let fileName = "quaternion_data.csv"
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        
        var fileContents = "w,x,y,z\n"
        for data in quaternionData {
            fileContents += "\(data.w),\(data.x),\(data.y),\(data.z)\n"
        }
        
        do {
            try fileContents.write(to: path, atomically: true, encoding: .utf8)
            activityItems = [path]
            activityViewControllerPresented = true
        } catch {
            print("Error saving file: \(error)")
        }
        
        quaternionData.removeAll()
    }
}
