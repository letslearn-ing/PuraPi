// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PuraPi",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(
            name: "PuraPi",
            targets: ["PuraPi"]
        ),
    ],
    targets: [
        .target(
            name: "PiDomain"
        ),
        .target(
            name: "PiRPC",
            dependencies: ["PiDomain"]
        ),
        .target(
            name: "WorkspaceKit",
            dependencies: ["PiDomain"]
        ),
        .executableTarget(
            name: "PuraPi",
            dependencies: ["PiDomain", "PiRPC", "WorkspaceKit"],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "PiDomainTests",
            dependencies: ["PiDomain"]
        ),
        .testTarget(
            name: "PiRPCTests",
            dependencies: ["PiRPC"]
        ),
        .testTarget(
            name: "WorkspaceKitTests",
            dependencies: ["WorkspaceKit"]
        ),
        .testTarget(
            name: "PuraPiTests",
            dependencies: ["PuraPi", "PiDomain", "PiRPC", "WorkspaceKit"]
        ),
    ]
)
