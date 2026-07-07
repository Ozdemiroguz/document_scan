// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "document_scan",
    platforms: [
        .iOS("13.0")
    ],
    products: [
        .library(name: "document-scan", targets: ["document_scan"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "document_scan",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                // Apple requires the plugin to bundle a privacy manifest. This
                // one declares no tracking, no collected data, and no
                // required-reason API usage — accurate for a Vision-only
                // detector that reads image files/frames and nothing else.
                .process("PrivacyInfo.xcprivacy"),
            ]
        )
    ]
)
