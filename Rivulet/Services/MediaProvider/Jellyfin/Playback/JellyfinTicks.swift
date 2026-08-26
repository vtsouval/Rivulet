// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

nonisolated enum JellyfinTicks {
    static let perSecond: Int64 = 10_000_000

    static func fromSeconds(_ seconds: TimeInterval) -> Int64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let ticks = seconds * Double(perSecond)
        guard ticks < Double(Int64.max) else { return Int64.max }
        return Int64(ticks.rounded())
    }

    static func toSeconds(_ ticks: Int64?) -> TimeInterval? {
        guard let ticks else { return nil }
        return TimeInterval(max(0, ticks)) / TimeInterval(perSecond)
    }
}
