// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

extension MediaProviderError {
    static func mappingJellyfin(_ error: Error) -> MediaProviderError {
        if let error = error as? MediaProviderError { return error }
        if let error = error as? JellyfinAPIError {
            switch error {
            case .unauthorized, .forbidden:
                return .unauthorized
            case .notFound:
                return .notFound
            case .transport(let code, _):
                switch code {
                case NSURLErrorNotConnectedToInternet,
                     NSURLErrorCannotConnectToHost,
                     NSURLErrorTimedOut,
                     NSURLErrorNetworkConnectionLost:
                    return .unreachable
                default:
                    return .backendSpecific(underlying: error.localizedDescription)
                }
            default:
                return .backendSpecific(underlying: error.localizedDescription)
            }
        }
        if error is CancellationError { return .unreachable }
        return .backendSpecific(underlying: error.localizedDescription)
    }
}

func jellyfinCall<T: Sendable>(_ body: () async throws -> T) async throws -> T {
    do {
        return try await body()
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        throw MediaProviderError.mappingJellyfin(error)
    }
}
