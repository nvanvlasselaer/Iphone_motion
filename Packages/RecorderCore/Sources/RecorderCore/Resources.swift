//
//  Resources.swift
//  RecorderCore
//

import Foundation

public enum RecorderCoreResources {
    /// The data format description copied into every session folder.
    public static var dataFormatURL: URL? {
        Bundle.module.url(forResource: "DATA_FORMAT", withExtension: "md")
    }
}
