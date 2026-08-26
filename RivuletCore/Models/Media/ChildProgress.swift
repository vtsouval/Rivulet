// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ChildProgress.swift
//  Rivulet
//
//  Watch-progress for hierarchical items (show/season). Carries the
//  played/total pair the UI uses for "12/24 watched" displays.
//

import Foundation

struct ChildProgress: Hashable, Sendable, Codable {
    let played: Int
    let total: Int
}
