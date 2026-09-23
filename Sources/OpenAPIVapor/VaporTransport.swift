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

public import HTTPTypes
public import OpenAPIRuntime
public import Vapor
import RoutingKit

public final class VaporTransport {

  /// A routes builder with which to register request handlers.
  internal var routesBuilder: any Vapor.RoutesBuilder

  /// The ceiling on a request body handed to a handler.
  internal let maxBodySize: BodySizeLimit

  /// Creates a new transport.
  /// - Parameters:
  ///   - routesBuilder: A routes builder with which to register request handlers.
  ///   - maxBodySize: The largest request body to accept; beyond it the request is rejected with
  ///     `413 Content Too Large`. Defaults to the application's `Routes/defaultMaxBodySize` of
  ///     16 KB. Bodies stream, so the ceiling is checked as the handler reads — a declared
  ///     `Content-Length` over it is refused up front, and a handler that never reads the body
  ///     never trips it.
  public init(routesBuilder: any Vapor.RoutesBuilder, maxBodySize: BodySizeLimit = .default) {
    self.routesBuilder = routesBuilder
    self.maxBodySize = maxBodySize
  }
}

extension VaporTransport: ServerTransport {
  public func register(
    _ handler:
      @concurrent @Sendable @escaping (
        HTTPTypes.HTTPRequest, OpenAPIRuntime.HTTPBody?, OpenAPIRuntime.ServerRequestMetadata
      ) async throws -> (HTTPTypes.HTTPResponse, OpenAPIRuntime.HTTPBody?),
    method: HTTPRequest.Method,
    path: String
  ) throws {
    // The closure below is `@Sendable` and the transport is not, so read the value out here.
    let maxBodySize = self.maxBodySize
    self.routesBuilder.on(
      method,
      [PathComponent](path)
    ) { vaporRequest in
      let request = try HTTPTypes.HTTPRequest(vaporRequest)
      let body = try VaporRequestBody(vaporRequest, maxBodySize: maxBodySize).httpBody
      let requestMetadata = try OpenAPIRuntime.ServerRequestMetadata(from: vaporRequest, forPath: path)
      let res = try await handler(request, body, requestMetadata)
      var response = try Vapor.Response(response: res.0, body: res.1)
      // `Response.init` derives Content-Length from the body; for HEAD the handler's value is the
      // one that matters, and restoring it is only safe when there is no body to contradict it.
      if res.1 == nil, let contentLength = res.0.headerFields[.contentLength] {
        response.headers[.contentLength] = contentLength
      }
      return response
    }
  }
}

enum VaporTransportError: Error {
  case duplicatePathParameter([String])
  case missingRequiredPathParameter(String)
}

extension [RoutingKit.PathComponent] {
  init(_ path: String) {
    self = path.split(
      separator: "/",
      omittingEmptySubsequences: true
    ).map { segment in
      if segment.first == "{", segment.last == "}" {
        return .parameter(String(segment.dropFirst().dropLast()))
      } else if segment.contains("{") {
        // A mixed segment like `/file/{name}.zip`, which `ServerTransport` allows. RoutingKit
        // spells these `:` plus the template. A plain `{name}` route alongside still shadows it.
        return .init(stringLiteral: ":\(segment)")
      } else {
        return .constant(String(segment))
      }
    }
  }
}

extension HTTPTypes.HTTPRequest {
  init(_ vaporRequest: Vapor.Request) throws {
    let queries = vaporRequest.url.query.map { "?\($0)" } ?? ""
    self.init(
      method: vaporRequest.method,
      scheme: vaporRequest.url.scheme,
      authority: vaporRequest.url.host,
      path: vaporRequest.url.path + queries,
      headerFields: vaporRequest.headers
    )
  }
}

extension OpenAPIRuntime.ServerRequestMetadata {
  init(from vaporRequest: Vapor.Request, forPath path: String) throws {
    self.init(pathParameters: try .init(from: vaporRequest, forPath: path))
  }
}

extension [String: Substring] {
  init(from vaporRequest: Vapor.Request, forPath path: String) throws {
    let keysAndValues = try [PathComponent](path).flatMap { component -> [String] in
      switch component {
      case .parameter(let parameter):
        return [parameter]
      // A mixed segment carries its parameters inside the template, each stored under its own name.
      case .partialParameter(_, _, let parameters):
        return parameters.map(String.init)
      case .constant, .anything, .catchall:
        return []
      }
    }.map { parameter -> (String, Substring) in
      guard let value = vaporRequest.parameters.get(parameter) else {
        throw VaporTransportError.missingRequiredPathParameter(parameter)
      }
      return (parameter, Substring(value))
    }
    let pathParameterDictionary = try Dictionary(
      keysAndValues,
      uniquingKeysWith: { _, _ in
        throw VaporTransportError.duplicatePathParameter(keysAndValues.map(\.0))
      })
    self = pathParameterDictionary
  }
}

extension Vapor.Response {
  init(response: HTTPTypes.HTTPResponse, body: OpenAPIRuntime.HTTPBody?) throws {
    self.init(
      status: response.status,
      headers: response.headerFields,
      body: try .init(body)
    )
  }
}

extension Vapor.Response.Body {
  init(_ body: OpenAPIRuntime.HTTPBody?) throws {
    guard let body else {
      self = .empty
      return
    }
    let stream: @Sendable (borrowing any HTTPBodyWriter & ~Escapable) async throws -> Void = { writer in
      for try await chunk in body {
        try await writer.write(chunk)
      }
    }
    switch body.length {
    case .known(let count):
      self = try .init(stream: stream, count: Int(clamping: count))
    case .unknown:
      self = .init(stream: stream)
    }
  }
}

public struct VaporRequestBody: Sendable {
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
  public init(_ request: Vapor.Request, maxBodySize: BodySizeLimit) throws {
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
  public var httpBody: OpenAPIRuntime.HTTPBody? {
    guard hasBody else {
      return nil
    }
    return HTTPBody(chunks, length: declaredLength, iterationBehavior: .single)
  }
}
