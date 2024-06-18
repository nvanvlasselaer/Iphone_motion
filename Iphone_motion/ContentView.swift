//
//  ContentView.swift
//  Iphone_motion
//
//  Created by Nicolas Van Vlasselaer on 18/06/2024.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var motionManager = MotionManager()
    
    var body: some View {
        VStack {
            Text("pitch = \(motionManager.pitch, specifier: "%.2f")")
            Text("roll = \(motionManager.roll, specifier: "%.2f")")
            Text("yaw = \(motionManager.yaw, specifier: "%.2f")")
            
            Text("quat w = \(motionManager.quaternion.w, specifier: "%.3f")")
            Text("quat x = \(motionManager.quaternion.x, specifier: "%.3f")")
            Text("quat y = \(motionManager.quaternion.y, specifier: "%.3f")")
            Text("quat z = \(motionManager.quaternion.z, specifier: "%.3f")")
            
            HStack {
                Button(action: {
                    motionManager.resetData()
                }) {
                    Text("Reset")
                }
                
                Button(action: {
                    motionManager.toggleDataUpdates()
                }) {
                    Text(motionManager.isUpdating ? "Pause" : "Resume")
                }
                
                Button(action: {
                    motionManager.toggleRecording()
                }) {
                    Text(motionManager.isRecording ? "Stop Recording" : "Start Recording")
                }
            }
            
            MotionChartView(data: motionManager.motionDataPoints)
                .frame(height: 300)
        }
        .padding()
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
