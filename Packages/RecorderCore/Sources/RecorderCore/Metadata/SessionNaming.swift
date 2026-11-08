//
//  SessionNaming.swift
//  RecorderCore
//

import Foundation

public enum SessionNaming {
    /// `yyyy-MM-dd_HH-mm-ss_<subject>_<trial>` (empty labels are left out).
    public static func folderName(start: Date, timeZone: TimeZone = .current, subject: String, trial: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        var parts = [formatter.string(from: start)]
        for label in [subject, trial] {
            let clean = sanitize(label)
            if !clean.isEmpty {
                parts.append(clean)
            }
        }
        return parts.joined(separator: "_")
    }

    /// Keeps ASCII letters, digits, "-", "_" and "."; anything else becomes "-". At most 40 characters.
    public static func sanitize(_ label: String) -> String {
        var result = ""
        var lastWasDash = false
        for scalar in label.unicodeScalars {
            let allowed = scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "-_.".unicodeScalars.contains(scalar))
            if allowed {
                result.unicodeScalars.append(scalar)
                lastWasDash = scalar == "-"
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }
        let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return String(trimmed.prefix(40))
    }

    /// Increments a trailing number, keeping zero padding: "T09" → "T10", "run3" → "run4", "base" → "base_2".
    public static func nextTrialLabel(_ label: String) -> String {
        let digits = String(label.reversed().prefix { $0.isASCII && $0.isNumber }.reversed())
        guard !digits.isEmpty, let value = Int(digits) else {
            return label.isEmpty ? "1" : label + "_2"
        }
        let prefix = label.dropLast(digits.count)
        let next = String(value + 1)
        let padded = String(repeating: "0", count: max(0, digits.count - next.count)) + next
        return prefix + padded
    }

    /// Appends "_2", "_3", … until the name is not in `existing`.
    public static func uniqued(_ name: String, existing: Set<String>) -> String {
        guard existing.contains(name) else { return name }
        var index = 2
        while existing.contains("\(name)_\(index)") {
            index += 1
        }
        return "\(name)_\(index)"
    }
}
