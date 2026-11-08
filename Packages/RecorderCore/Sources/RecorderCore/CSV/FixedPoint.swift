//
//  FixedPoint.swift
//  RecorderCore
//
//  Locale-independent fixed-decimal number formatting for CSV files ("." decimal separator,
//  no thousands separators, no exponent, rounding half away from zero, no "-0.000").
//

import Foundation

public enum FixedPoint {
    private static let powersOfTen: [UInt64] = {
        var values: [UInt64] = [1]
        for _ in 1...18 { values.append(values[values.count - 1] * 10) }
        return values
    }()

    /// Appends `value` with exactly `decimals` digits after the point. Non-finite values append
    /// nothing, which yields an empty CSV field.
    public static func append(_ value: Double, decimals: Int, to out: inout [UInt8]) {
        precondition((0...9).contains(decimals), "decimals must be 0...9")
        guard value.isFinite else { return }
        let scaled = (abs(value) * Double(powersOfTen[decimals])).rounded(.toNearestOrAwayFromZero)
        guard scaled < 9.0e18 else {
            // Far outside any sensor range; fall back to Swift's locale-independent description.
            out.append(contentsOf: Array(String(value).utf8))
            return
        }
        let magnitude = UInt64(scaled)
        if magnitude != 0 && value < 0 {
            out.append(UInt8(ascii: "-"))
        }
        appendUnsigned(magnitude / powersOfTen[decimals], to: &out)
        if decimals > 0 {
            out.append(UInt8(ascii: "."))
            appendUnsigned(magnitude % powersOfTen[decimals], minimumDigits: decimals, to: &out)
        }
    }

    /// Appends a signed integer.
    public static func append(_ value: Int, to out: inout [UInt8]) {
        if value < 0 {
            out.append(UInt8(ascii: "-"))
        }
        appendUnsigned(value.magnitude.toUInt64, to: &out)
    }

    public static func string(_ value: Double, decimals: Int) -> String {
        var out: [UInt8] = []
        append(value, decimals: decimals, to: &out)
        return String(decoding: out, as: UTF8.self)
    }

    private static func appendUnsigned(_ value: UInt64, minimumDigits: Int = 1, to out: inout [UInt8]) {
        var digits: [UInt8] = []
        var v = value
        repeat {
            digits.append(UInt8(ascii: "0") + UInt8(v % 10))
            v /= 10
        } while v > 0
        if digits.count < minimumDigits {
            digits.append(contentsOf: repeatElement(UInt8(ascii: "0"), count: minimumDigits - digits.count))
        }
        out.append(contentsOf: digits.reversed())
    }
}

private extension UInt {
    var toUInt64: UInt64 { UInt64(self) }
}

/// RFC 4180 quoting for free-text CSV fields.
public enum CSVText {
    public static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public static func line(_ fields: [String]) -> String {
        fields.map(escape).joined(separator: ",") + "\n"
    }
}
