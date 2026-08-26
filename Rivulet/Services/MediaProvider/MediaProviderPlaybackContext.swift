// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Provider-neutral payload passed from a detail surface into the existing
/// Aether player. Backend negotiation stays outside the rendering layer.
struct MediaProviderPlaybackContext: Sendable {
    let detail: MediaItemDetail
    let streamInfo: StreamInfo
    let provider: any MediaProvider

    var itemRef: MediaItemRef { detail.item.ref }

    var progressReporter: any ProgressReporter {
        provider.progressReporter(for: itemRef, streamInfo: streamInfo)
    }
}
