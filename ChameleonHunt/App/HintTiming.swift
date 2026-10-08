//
//  HintTiming.swift
//  When, if ever, the seeker gets a clue.
//
//  There used to be Easy / Classic / Tricky presets here as well. They weren't needed,
//  so the two settings they bundled (time and clue) live in settings on their own.
//

import Foundation

/// When, if ever, the seeker is told what they're looking for.
enum HintTiming: Int, CaseIterable, Identifiable {
    case never = 0
    case oneMinute = 60
    case thirtySeconds = 30

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .never:          return "No hint"
        case .oneMinute:      return "At 1:00 left"
        case .thirtySeconds:  return "At 0:30 left"
        }
    }

    var seconds: Int { rawValue }
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}
