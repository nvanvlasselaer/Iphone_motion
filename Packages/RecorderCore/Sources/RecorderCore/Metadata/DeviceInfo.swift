//
//  DeviceInfo.swift
//  RecorderCore
//

import Foundation

public struct DeviceInfo: Codable, Equatable, Sendable {
    /// Hardware model, e.g. "iPhone16,1" or "Watch7,5".
    public var modelIdentifier: String
    public var systemName: String
    public var systemVersion: String
    /// "<marketing version> (<build>)".
    public var appVersion: String
    /// Watch only: wrist the Watch is configured for ("left"/"right").
    public var wristLocation: String?
    /// Watch only: side of the Digital Crown ("left"/"right").
    public var crownOrientation: String?

    public init(
        modelIdentifier: String,
        systemName: String,
        systemVersion: String,
        appVersion: String,
        wristLocation: String? = nil,
        crownOrientation: String? = nil
    ) {
        self.modelIdentifier = modelIdentifier
        self.systemName = systemName
        self.systemVersion = systemVersion
        self.appVersion = appVersion
        self.wristLocation = wristLocation
        self.crownOrientation = crownOrientation
    }

    /// Info for the device running this code.
    public static func current(bundle: Bundle = .main) -> DeviceInfo {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if os(watchOS)
        let systemName = "watchOS"
        #elseif os(iOS)
        let systemName = "iOS"
        #else
        let systemName = "macOS"
        #endif
        return DeviceInfo(
            modelIdentifier: currentModelIdentifier(),
            systemName: systemName,
            systemVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            appVersion: appVersion(bundle: bundle)
        )
    }

    public static func currentModelIdentifier() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    public static func appVersion(bundle: Bundle = .main) -> String {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }
}
