//===----------------------------------------------------------------------===//
//
// This source file is part of the Hummingbird server framework project
//
// Copyright (c) 2021-2021 the Hummingbird authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See hummingbird/CONTRIBUTORS.txt for the list of Hummingbird authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIO

/// Protocol for object that produces a response given a request
///
/// This is the core protocol for Hummingbird. It defines an object that can respond to a request.
public protocol HBResponder {
    /// Return EventLoopFuture that will be fulfilled with response to the request supplied
    func respond(to request: HBRequest) -> EventLoopFuture<HBResponse>
}

/// Responder that calls supplied closure
public struct HBCallbackResponder: HBResponder {
    let callback: (HBRequest) -> EventLoopFuture<HBResponse>

    public init(callback: @escaping (HBRequest) -> EventLoopFuture<HBResponse>) {
        self.callback = callback
    }

    /// Return EventLoopFuture that will be fulfilled with response to the request supplied
    public func respond(to request: HBRequest) -> EventLoopFuture<HBResponse> {
        return self.callback(request)
    }
}

/// Responder that calls supplied closure
public struct HBAsyncCallbackResponder: HBResponder {
    let callback: (HBRequest) async throws -> HBResponse

    public init(callback: @escaping (HBRequest) async throws -> HBResponse) {
        self.callback = callback
    }

    /// Return EventLoopFuture that will be fulfilled with response to the request supplied
    public func respond(to request: HBRequest) -> EventLoopFuture<HBResponse> {
        @asyncHandler func respond(to request: HBRequest, promise: EventLoopPromise<HBResponse>) {
            do {
                let response = try await callback(request)
                promise.succeed(response)
            } catch {
                promise.fail(error)
            }
        }
        let promise = request.eventLoop.makePromise(of: HBResponse.self)
        respond(to: request, promise: promise)
        return promise.futureResult
    }
}
