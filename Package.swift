// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Flipdial",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Flipdial",
            path: "Sources/Flipdial",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("PDFKit"),
                .linkedFramework("QuickLookUI"),
            ]
        )
    ]
)
