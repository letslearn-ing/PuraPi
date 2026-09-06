// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WorkPi",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(
            name: "WorkPi",
            targets: ["WorkPi"]
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
            name: "WorkPi",
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
            name: "WorkPiTests",
            dependencies: ["WorkPi", "PiDomain", "PiRPC", "WorkspaceKit"]
        ),
    ]
)
