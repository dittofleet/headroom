import Foundation
import Testing
@testable import HeadroomMac

@Test func cliLinkOnlyManagesItsOwnLink() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let bin = dir.appendingPathComponent("bin")
    let binary = dir.appendingPathComponent("New/Headroom.app/Contents/MacOS/headroom-cli")
    try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: binary)
    let link = CLILink(binary: binary, binDir: bin)

    #expect(link.state == .missing)
    try link.install()
    #expect(link.state == .installed)
    try link.install()
    #expect(link.state == .installed)

    // A link to a copy of the app that has since gone is repaired.
    try FileManager.default.removeItem(at: link.link)
    try FileManager.default.createSymbolicLink(atPath: link.link.path, withDestinationPath: dir.appendingPathComponent("Old/Headroom.app/Contents/MacOS/headroom-cli").path)
    #expect(link.state == .stale)
    link.repairIfStale()
    #expect(link.state == .installed)
    try link.uninstall()
    #expect(link.state == .missing)

    // Another copy of the app that is still there keeps its link.
    let other = dir.appendingPathComponent("Other/Headroom.app/Contents/MacOS/headroom-cli")
    try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: other)
    try FileManager.default.createSymbolicLink(atPath: link.link.path, withDestinationPath: other.path)
    #expect(link.state == .foreign)
    link.repairIfStale()
    #expect(link.state == .foreign)
    try FileManager.default.removeItem(at: link.link)

    // A headroom-cli outside an app bundle was linked by hand.
    try FileManager.default.createSymbolicLink(atPath: link.link.path, withDestinationPath: dir.appendingPathComponent("tools/headroom-cli").path)
    #expect(link.state == .foreign)
    link.repairIfStale()
    #expect(link.state == .foreign)
    try FileManager.default.removeItem(at: link.link)

    // Someone else's file is refused, and survives an uninstall, until the
    // user agrees to replace it.
    try Data("mine".utf8).write(to: link.link)
    #expect(link.state == .foreign)
    #expect(throws: CLILink.Failure.self) { try link.install() }
    try link.uninstall()
    #expect(try Data(contentsOf: link.link) == Data("mine".utf8))
    try link.install(replacing: true)
    #expect(link.state == .installed)
    #expect(try FileManager.default.contentsOfDirectory(atPath: bin.path) == ["headroom"])
}
