// swift-tools-version: 6.4

import PackageDescription

let swiftSettings: [SwiftSetting] = [
  /// https://github.com/apple/swift-evolution/blob/main/proposals/0335-existential-any.md
  /// Require `any` for existential types.
  .enableUpcomingFeature("ExistentialAny"),
  /// https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md
  /// Make `async` functions inherit their caller's isolation. Vapor enables this too, and the two
  /// modules have to agree: otherwise passing an `async` closure to a Vapor API crosses an
  /// isolation boundary and is rejected.
  .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
  name: "swift-openapi-vapor",
  platforms: [
    .macOS("26.2"),
    .iOS("26.2"),
    .tvOS("26.2"),
    .watchOS("26.2"),
  ],
  products: [
    .library(name: "OpenAPIVapor", targets: ["OpenAPIVapor"])
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-openapi-runtime.git", from: "1.12.1", traits: []),
    .package(url: "https://github.com/vapor/vapor.git", exact: "5.0.0-beta.2"),
  ],
  targets: [
    .target(
      name: "OpenAPIVapor",
      dependencies: [
        .product(name: "Vapor", package: "vapor"),
        .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
      ],
      swiftSettings: swiftSettings
    ),
    .testTarget(
      name: "OpenAPIVaporTests",
      dependencies: [
        "OpenAPIVapor",
        .product(name: "VaporTesting", package: "vapor"),
      ],
      swiftSettings: swiftSettings
    ),
  ]
)
