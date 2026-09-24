// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ApexTerm",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "ApexTerm",
            targets: ["ApexTerm"]
        ),
        .library(
            name: "ApexCore",
            targets: ["ApexCore"]
        ),
        .library(
            name: "ApexSSH",
            targets: ["ApexSSH"]
        ),
        .library(
            name: "ApexTerminal",
            targets: ["ApexTerminal"]
        ),
        .library(
            name: "ApexUI",
            targets: ["ApexUI"]
        )
    ],
    dependencies: [],
    targets: [
        // MARK: - Core Domain & Security
        .target(
            name: "ApexCore",
            dependencies: [],
            path: "Sources/ApexCore"
        ),
        
        // MARK: - SSH & Agentless Metrics Protocol Layer
        .target(
            name: "ApexSSH",
            dependencies: ["ApexCore"],
            path: "Sources/ApexSSH"
        ),
        
        // MARK: - Metal Terminal Emulation & Buffer Engine
        .target(
            name: "ApexTerminal",
            dependencies: ["ApexCore"],
            path: "Sources/ApexTerminal"
        ),
        
        // MARK: - High-Performance Native UI (SwiftUI + AppKit + Swift Charts)
        .target(
            name: "ApexUI",
            dependencies: ["ApexCore", "ApexSSH", "ApexTerminal"],
            path: "Sources/ApexUI"
        ),
        
        // MARK: - Executable App Entry Point
        .executableTarget(
            name: "ApexTerm",
            dependencies: ["ApexUI", "ApexCore", "ApexSSH", "ApexTerminal"],
            path: "Sources/ApexTerm"
        ),
        
        // MARK: - Unit Tests
        .testTarget(
            name: "ApexCoreTests",
            dependencies: ["ApexCore"],
            path: "Tests/ApexCoreTests"
        ),
        .testTarget(
            name: "ApexSSHTests",
            dependencies: ["ApexSSH", "ApexCore", "ApexTerminal"],
            path: "Tests/ApexSSHTests"
        )
    ]
)
