//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift OpenAPI Vapor open source project
//
// Copyright (c) 2026 the Swift OpenAPI Vapor project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import HTTPTypes
import OpenAPIRuntime
import Synchronization
import Testing
import Vapor
import VaporTesting
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

@testable import OpenAPIVapor

/// Which testing transport a test runs over. `Application.Method` itself is not `Sendable`, so it
/// cannot be passed to `@Test(arguments:)` directly.
enum TestTransport: Sendable, CaseIterable, CustomStringConvertible {
  case inMemory
  case liveServer

  var method: Application.Method {
    switch self {
    case .inMemory: .inMemory
    case .liveServer: .running
    }
  }

  var description: String {
    switch self {
    case .inMemory: "in memory"
    case .liveServer: "live server"
    }
  }
}

struct VaporTransportTests {

  /// A HEAD response declares the length of the body a GET would have returned, and sends no body.
  /// Over a real connection this also proves the length survives the wire with nothing following.
  @Test(arguments: TestTransport.allCases)
  func headRequestExplicitContentLength(over transport: TestTransport) async throws {
    try await withApp { app in
      let openAPITransport = VaporTransport(routesBuilder: app)
      let response = HTTPTypes.HTTPResponse(
        status: .ok,
        headerFields: [
          .contentLength: "42"
        ]
      )
      try openAPITransport.register(
        { _, _, _ in (response, nil) },
        method: .head,
        path: "/test"
      )

      try await app.testing(transport.method) { client in
        let res = try await client.send(.head, to: "/test")
        #expect(res.status == .ok)
        #expect(res.headers[.contentLength] == "42")
        // In memory there is no body at all, over a connection an empty one; same thing here.
        let bodyString = try await res.body.string() ?? ""
        #expect(bodyString == "")
      }
    }
  }

  @Test
  func requestConversion() async throws {
    try await withApp { app in
      // POST /hello/{name}/world
      app.post("hello", ":name", "world") { vaporRequest -> Response in
        // Hijack the request handler to test the request-conversion functions.
        let expectedRequest = HTTPTypes.HTTPRequest(
          method: .post,
          scheme: nil,
          authority: nil,
          path: "/hello/Maria/world?greeting=Howdy",
          headerFields: [
            HTTPField.Name("X-Mumble")!: "mumble",
            HTTPField.Name("content-length")!: "4",
          ]
        )
        let expectedRequestMetadata = ServerRequestMetadata(
          pathParameters: ["name": "Maria"]
        )
        let request = try HTTPTypes.HTTPRequest(vaporRequest)
        // Mirrors how `register` builds the body. Nothing here may throw: this runs inside the
        // route, so a throw would surface as a 500 and hide the real assertion.
        let data = try await vaporRequest.body.collect() ?? Data()
        let body = HTTPBody(data, length: .known(Int64(data.count)), iterationBehavior: .multiple)
        let collectedBody = try await [UInt8](collecting: body, upTo: .max)
        let metadata = try ServerRequestMetadata(from: vaporRequest, forPath: "/hello/{name}/world")
        #expect(request == expectedRequest)
        #expect(collectedBody == [UInt8]("👋".utf8))
        #expect(metadata == expectedRequestMetadata)

        // Use the response-conversion to create the Vapor response for returning.
        let response = HTTPTypes.HTTPResponse(
          status: .created,
          headerFields: [
            HTTPField.Name("X-Mumble")!: "mumble"
          ]
        )
        return try Vapor.Response(response: response, body: .init([UInt8]("👋".utf8)))
      }

      try await app.testing { client in
        let res = try await client.post(
          "/hello/Maria/world?greeting=Howdy",
          headers: [HTTPField.Name("X-Mumble")!: "mumble"]
        ) { request in
          request.body = .init(string: "👋")
        }
        #expect(res.status.code == 201)
      }
    }
  }

  /// The streaming branch of `Response.Body`: a body of unknown length has to reach the client
  /// chunked, in order and whole.
  @Test(arguments: TestTransport.allCases)
  func streamingResponseBodyOfUnknownLength(over transport: TestTransport) async throws {
    try await withApp { app in
      let openAPITransport = VaporTransport(routesBuilder: app)
      let chunks: [HTTPBody.ByteChunk] = [ArraySlice("Hello, ".utf8), ArraySlice("world!".utf8)]
      try openAPITransport.register(
        { _, _, _ in
          let stream = AsyncStream<HTTPBody.ByteChunk> { continuation in
            for chunk in chunks {
              continuation.yield(chunk)
            }
            continuation.finish()
          }
          return (HTTPTypes.HTTPResponse(status: .ok), HTTPBody(stream, length: .unknown))
        },
        method: .get,
        path: "/stream"
      )

      try await app.testing(transport.method) { client in
        let res = try await client.get("/stream")
        #expect(res.status == .ok)
        // An unknown length means chunked framing, so no `Content-Length` is declared.
        #expect(res.headers[.contentLength] == nil)
        try #expect(await res.body.requireString() == "Hello, world!")
      }
    }
  }

  /// RFC 9112 §6.1 forbids `Content-Length` alongside `Transfer-Encoding`, so a length the handler
  /// declared must not be restored onto a chunked response.
  @Test(arguments: TestTransport.allCases)
  func unknownLengthBodyIgnoresDeclaredContentLength(over transport: TestTransport) async throws {
    try await withApp { app in
      let openAPITransport = VaporTransport(routesBuilder: app)
      try openAPITransport.register(
        { _, _, _ in
          let stream = AsyncStream<HTTPBody.ByteChunk> { continuation in
            continuation.yield(ArraySlice("hi".utf8))
            continuation.finish()
          }
          return (
            HTTPTypes.HTTPResponse(status: .ok, headerFields: [.contentLength: "999"]),
            HTTPBody(stream, length: .unknown)
          )
        },
        method: .get,
        path: "/stream"
      )

      try await app.testing(transport.method) { client in
        let res = try await client.get("/stream")
        #expect(res.status == .ok)
        #expect(res.headers[.contentLength] == nil)
        try #expect(await res.body.requireString() == "hi")
      }
    }
  }

  /// A chunked upload arrives without `Content-Length`. The transport collects it first, so the
  /// length it reports is the one it holds, not the one the client declared.
  @Test
  func chunkedRequestBodyReportsCollectedLength() async throws {
    try await withApp { app in
      let openAPITransport = VaporTransport(routesBuilder: app)
      let seenLength = Mutex<HTTPBody.Length?>(nil)
      try openAPITransport.register(
        { _, body, _ in
          seenLength.withLock { $0 = body?.length }
          return (HTTPTypes.HTTPResponse(status: .ok), nil)
        },
        method: .post,
        path: "/upload"
      )

      try await app.testing(.running) { client in
        let res = try await client.post("/upload") { request in
          // A stream without a count is framed chunked, so no `Content-Length` is sent.
          request.body = .init(stream: { writer in
            try await writer.write("hello".utf8)
          })
        }
        #expect(res.status == .ok)
      }

      #expect(seenLength.withLock { $0 } == .known(5))
    }
  }

  /// Collecting implies a ceiling, by default the application's 16 KB. The Vapor 4 transport
  /// streamed and had no limit, so this is the behaviour change a migrating user will notice.
  ///
  /// Both ceiling tests use a real connection on purpose: the in-memory client hands over an
  /// already-collected body, and `collect(max:)` returns a buffered body unchecked.
  @Test
  func requestBodyOverTheDefaultCeilingIsRejected() async throws {
    try await withApp { app in
      let openAPITransport = VaporTransport(routesBuilder: app)
      try openAPITransport.register(
        { _, _, _ in (HTTPTypes.HTTPResponse(status: .ok), nil) },
        method: .post,
        path: "/upload"
      )

      try await app.testing(.running) { client in
        let res = try await client.post("/upload") { request in
          request.body = .init(string: String(repeating: "a", count: 21 * 1024))
        }
        #expect(res.status == .contentTooLarge)
      }
    }
  }

  /// The ceiling is the transport's to set, so an API whose operations take larger payloads does
  /// not have to raise the limit for the whole application.
  @Test
  func requestBodyCeilingCanBeRaised() async throws {
    try await withApp { app in
      let openAPITransport = VaporTransport(routesBuilder: app, maxBodySize: .specified("64kb"))
      try openAPITransport.register(
        { _, body, _ in
          #expect(body?.length == .known(Int64(21 * 1024)))
          return (HTTPTypes.HTTPResponse(status: .ok), nil)
        },
        method: .post,
        path: "/upload"
      )

      try await app.testing(.running) { client in
        let res = try await client.post("/upload") { request in
          request.body = .init(string: String(repeating: "a", count: 21 * 1024))
        }
        #expect(res.status == .ok)
      }
    }
  }

  /// A segment mixing a parameter with literal text, which `ServerTransport` allows, has to match
  /// and yield its parameter. It used to become a constant containing braces, so the route was dead.
  ///
  /// Partly addresses https://github.com/vapor/swift-openapi-vapor/issues/23: registering
  /// `/{scope}/{name}/{version}` alongside still shadows this route, because RoutingKit's trie
  /// takes a wildcard branch before a partial one and only backtracks when it dead-ends. That
  /// precedence is RoutingKit's to change.
  @Test(arguments: TestTransport.allCases)
  func mixedPathSegmentRoutesAndYieldsItsParameter(over transport: TestTransport) async throws {
    try await withApp { app in
      let openAPITransport = VaporTransport(routesBuilder: app)
      try openAPITransport.register(
        { _, _, metadata in
          (
            HTTPTypes.HTTPResponse(status: .ok),
            HTTPBody("archive:\(metadata.pathParameters["version"] ?? "")")
          )
        },
        method: .get,
        path: "/{scope}/{name}/{version}.zip"
      )

      try await app.testing(transport.method) { client in
        let archive = try await client.get("/pointfreeco/swift-clocks/1.0.6.zip")
        #expect(archive.status == .ok)
        // The `.zip` suffix is literal, so it is not part of the captured version.
        try #expect(await archive.body.requireString() == "archive:1.0.6")
      }
    }
  }

  /// An error thrown by the handler must reach the client as a failure rather than be swallowed
  /// into a success by the transport.
  @Test
  func handlerErrorSurfacesToClient() async throws {
    struct HandlerFailure: Error {}
    try await withApp { app in
      let openAPITransport = VaporTransport(routesBuilder: app)
      try openAPITransport.register(
        { _, _, _ in throw HandlerFailure() },
        method: .get,
        path: "/boom"
      )

      try await app.testing { client in
        let res = try await client.get("/boom")
        #expect(res.status == .internalServerError)
      }
    }
  }

  @Test
  func handlerRegistration() async throws {
    try await withApp { app in
      let transport = VaporTransport(routesBuilder: app)
      let response = HTTPTypes.HTTPResponse(status: .created)
      try transport.register(
        { _, _, _ in (response, nil) },
        method: .post,
        path: "/hello/{name}"
      )

      #expect(app.routes.all.first?.path == ["hello", ":name"])

      try await app.testing { client in
        let res = try await client.post(
          "/hello/Maria?greeting=Howdy",
          headers: [HTTPField.Name("X-Mumble")!: "mumble"]
        ) { request in
          request.body = .init(string: "👋")
        }
        #expect(res.status == .created)
      }
    }
  }
}
