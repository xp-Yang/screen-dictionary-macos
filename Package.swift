// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScreenDictionary",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "ScreenDictionary", targets: ["ScreenDictionary"])],
    targets: [.executableTarget(name: "ScreenDictionary")],
    swiftLanguageModes: [.v5]
)
