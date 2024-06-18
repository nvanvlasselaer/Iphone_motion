//
//  ContentView.swift
//  Iphone_motion
//
//  Created by Nicolas Van Vlasselaer on 18/06/2024.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var motionManager = MotionManager()
    @State private var isMotionDataExpanded = false
    @State private var isQuaternionExpanded = false
    
    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width > geometry.size.height { // Landscape mode
                HStack(spacing: 0) {
                    MotionChartView(data: motionManager.motionDataPoints)
                        .frame(width: geometry.size.width / 1.8, height: geometry.size.height)
                        .edgesIgnoringSafeArea(.all)
                    
                    VStack {
                        VStack {
                            DisclosureGroup(isExpanded: $isMotionDataExpanded) {
                                Group {
                                    Text("Pitch: \(motionManager.pitch, specifier: "%.2f")")
                                    Text("Roll: \(motionManager.roll, specifier: "%.2f")")
                                    Text("Yaw: \(motionManager.yaw, specifier: "%.2f")")
                                }
                                .foregroundColor(.secondary)
                            } label: {
                                HStack {
                                    Text("Euler Angles")
                                        .font(.headline)
                                    Spacer()
                                    Image(systemName: isMotionDataExpanded ? "chevron.up" : "chevron.down")
                                        .imageScale(.small)
                                }
                            }
                            .padding(.vertical, 5)
                            
                            DisclosureGroup(isExpanded: $isQuaternionExpanded) {
                                Group {
                                    Text("Quaternion W: \(motionManager.quaternion.w, specifier: "%.3f")")
                                    Text("Quaternion X: \(motionManager.quaternion.x, specifier: "%.3f")")
                                    Text("Quaternion Y: \(motionManager.quaternion.y, specifier: "%.3f")")
                                    Text("Quaternion Z: \(motionManager.quaternion.z, specifier: "%.3f")")
                                }
                                .foregroundColor(.secondary)
                            } label: {
                                HStack {
                                    Text("Quaternions")
                                        .font(.headline)
                                    Spacer()
                                    Image(systemName: isQuaternionExpanded ? "chevron.up" : "chevron.down")
                                        .imageScale(.small)
                                }
                            }
                            .padding(.vertical, 5)
                        }
                        .padding(.horizontal)
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(10)
                        .padding(.top, UIApplication.shared.connectedScenes
                                         .compactMap { $0 as? UIWindowScene }
                                         .first?.windows.first?.safeAreaInsets.top ?? 0)
                        .padding(.bottom, UIApplication.shared.connectedScenes
                                            .compactMap { $0 as? UIWindowScene }
                                            .first?.windows.first?.safeAreaInsets.bottom ?? 0)
                        HStack {
                            Button(action: {
                                motionManager.resetData()
                            }) {
                                Text("Reset")
                                    .padding()
                                    .foregroundColor(.white)
                                    .background(Color.blue)
                                    .cornerRadius(8)
                            }
                            
                            Button(action: {
                                motionManager.toggleDataUpdates()
                            }) {
                                Text(motionManager.isUpdating ? "Pause" : "Resume")
                                    .padding()
                                    .foregroundColor(.white)
                                    .background(motionManager.isUpdating ? Color.red : Color.green)
                                    .cornerRadius(8)
                            }
                            
                            Button(action: {
                                motionManager.toggleRecording()
                            }) {
                                Text(motionManager.isRecording ? "Stop Recording" : "Start Recording")
                                    .padding()
                                    .foregroundColor(.white)
                                    .background(motionManager.isRecording ? Color.red : Color.green)
                                    .cornerRadius(8)
                            }
                        }
                        .padding()
                    }
                }
            } else { // Portrait mode
                VStack {
                    VStack {
                        DisclosureGroup(isExpanded: $isMotionDataExpanded) {
                            Group {
                                Text("Pitch: \(motionManager.pitch, specifier: "%.2f") ° ")
                                Text("Roll: \(motionManager.roll, specifier: "%.2f") ° ")
                                Text("Yaw: \(motionManager.yaw, specifier: "%.2f") ° ")
                            }
                            .foregroundColor(.secondary)
                        } label: {
                            HStack {
                                Text("Euler Angles")
                                    .font(.headline)
                                Spacer()
                                Image(systemName: isMotionDataExpanded ? "chevron.up" : "chevron.down")
                                    .imageScale(.small)
                            }
                        }
                        .padding(.vertical, 5)
                        
                        DisclosureGroup(isExpanded: $isQuaternionExpanded) {
                            Group {
                                Text("Quaternion W: \(motionManager.quaternion.w, specifier: "%.3f")")
                                Text("Quaternion X: \(motionManager.quaternion.x, specifier: "%.3f")")
                                Text("Quaternion Y: \(motionManager.quaternion.y, specifier: "%.3f")")
                                Text("Quaternion Z: \(motionManager.quaternion.z, specifier: "%.3f")")
                            }
                            .foregroundColor(.secondary)
                        } label: {
                            HStack {
                                Text("Quaternions")
                                    .font(.headline)
                                Spacer()
                                Image(systemName: isQuaternionExpanded ? "chevron.up" : "chevron.down")
                                    .imageScale(.small)
                            }
                        }
                        .padding(.vertical, 5)
                    }
                    .padding(.horizontal)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)
                    .padding(.top, UIApplication.shared.connectedScenes
                                     .compactMap { $0 as? UIWindowScene }
                                     .first?.windows.first?.safeAreaInsets.top ?? 0)
                    .padding(.bottom, UIApplication.shared.connectedScenes
                                        .compactMap { $0 as? UIWindowScene }
                                        .first?.windows.first?.safeAreaInsets.bottom ?? 0)
                    
                    HStack {
                        Button(action: {
                            motionManager.resetData()
                        }) {
                            Text("Reset")
                                .padding()
                                .foregroundColor(.white)
                                .background(Color.blue)
                                .cornerRadius(8)
                        }
                        
                        Button(action: {
                            motionManager.toggleDataUpdates()
                        }) {
                            Text(motionManager.isUpdating ? "Pause" : "Resume")
                                .padding()
                                .foregroundColor(.white)
                                .background(motionManager.isUpdating ? Color.red : Color.green)
                                .cornerRadius(8)
                        }
                        
                        Button(action: {
                            motionManager.toggleRecording()
                        }) {
                            Text(motionManager.isRecording ? "Stop Recording" : "Start Recording")
                                .padding()
                                .foregroundColor(.white)
                                .background(motionManager.isRecording ? Color.red : Color.green)
                                .cornerRadius(8)
                        }
                    }
                    .padding()
                    
                    MotionChartView(data: motionManager.motionDataPoints)
                        .frame(height: 300)
                        .padding()
                    
                    // Add your image here
                    Image("experimental anatomy")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding()
                }
            }
        }
        .edgesIgnoringSafeArea(.all)
    }
}





struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
