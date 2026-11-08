//
//  AboutView.swift
//  Iphone_motion
//

import RecorderCore
import SwiftUI

struct AboutView: View {
    @State private var dataFormat = ""

    var body: some View {
        List {
            Section {
                Image("experimental anatomy")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Experimental Anatomy Research Group")
                LabeledContent("Version", value: DeviceInfo.appVersion())
                Text("Records inertial sensor data of the iPhone and the Apple Watch for offline kinematic analysis. Each session folder holds CSV files, session.json with all metadata, and DATA_FORMAT.md describing every column and how to synchronize the devices.")
                    .font(.callout)
            }
            Section("Data format") {
                Text(dataFormat)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let url = RecorderCoreResources.dataFormatURL {
                dataFormat = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
        }
    }
}
