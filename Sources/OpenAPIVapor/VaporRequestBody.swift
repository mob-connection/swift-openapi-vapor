//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift OpenAPI Vapor open source project
//
// Copyright (c) 2023 the Swift OpenAPI Vapor project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import HTTPTypes
import OpenAPIRuntime
import Vapor

struct VaporRequestBody: Sendable {
  /// The body as a lazy sequence of chunks: one `withReader` scope per chunk, so nothing
  /// non-escapable outlives a read. The stream lives in the request, so the position carries
  /// from one call to the next.
  struct RequestBodyChunks: AsyncSequence, Sendable {
    typealias Element = HTTPBody.ByteChunk

    let request: Vapor.Request
    let maxBodySize: Int

    func makeAsyncIterator() -> Iterator {
      Iterator(request: request, maxBodySize: maxBodySize)
    }

    struct Iterator: AsyncIteratorProtocol {
      let request: Vapor.Request
      let maxBodySize: Int
      private var bytesRead = 0
      private var finished = false

      init(request: Vapor.Request, maxBodySize: Int) {
        self.request = request
        self.maxBodySize = maxBodySize
      }

      mutating func next() async throws -> Element? {
        // Bound out of `self` before the closures: `self` is already `inout` here.
        let request = self.request
        // A read can come back empty without ending the body, and returning `nil` would say the
        // body is over — so keep reading until there are bytes or the stream ends.
        while !finished {
          let (chunk, isEnd) = try await request.body.withReader { reader in
            try await reader.read { span, isEnd -> (Element?, Bool) in
              // Take the bytes before looking at the flag: a terminal read may carry a final batch.
              let chunk: Element? = span.isEmpty
                ? nil
                : span.withUnsafeBufferPointer { unsafe ArraySlice($0) }
              return (chunk, isEnd)
            }
          }
          if isEnd {
            finished = true
          }
          if let chunk {
            bytesRead += chunk.count
            guard bytesRead <= maxBodySize else {
              throw Abort(.contentTooLarge)
            }
            return chunk
          }
        }
        return nil
      }
    }
  }

  private let chunks: RequestBodyChunks
  private let declaredLength: HTTPBody.Length
  private let hasBody: Bool

  /// - Throws: `Abort` with `.contentTooLarge` when the declared `Content-Length` already exceeds
  ///   `maxBodySize`, refusing an oversized upload before any of it is read.
  init(_ request: Vapor.Request, maxBodySize: BodySizeLimit) throws {
    // `BodySizeLimit.bytes(default:)` is internal to Vapor, so resolve the ceiling here.
    let limit: Int = switch maxBodySize {
    case .default: request.maxBodySize.value
    case .unlimited: .max
    case .specified(let count): count.value
    }

    let declared = request.headers[.contentLength].flatMap { Int($0) }
    if let declared, declared > limit {
      throw Abort(.contentTooLarge)
    }

    // Nothing is collected up front, so the framing is the only signal that a body exists.
    self.hasBody = declared != nil || request.headers[.transferEncoding] != nil
    self.declaredLength = declared.map { .known(Int64($0)) } ?? .unknown
    self.chunks = RequestBodyChunks(request: request, maxBodySize: limit)
  }

  /// The body as an `HTTPBody`, or `nil` when the request carries none.
  ///
  /// `.single` because the bytes come off a socket and cannot be read twice.
  var httpBody: OpenAPIRuntime.HTTPBody? {
    guard hasBody else {
      return nil
    }
    return HTTPBody(chunks, length: declaredLength, iterationBehavior: .single)
  }
}
