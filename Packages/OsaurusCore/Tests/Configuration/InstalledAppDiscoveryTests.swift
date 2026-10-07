//
//  InstalledAppDiscoveryTests.swift
//  OsaurusCoreTests
//
//  Deterministic tests for local app-bundle discovery.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Installed app discovery")
struct InstalledAppDiscoveryTests {
    @Test("reads app metadata recursively and ignores helper apps inside bundles")
    func discoversAppsAndSkipsNestedHelpers() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try makeApp(
            at: root.appendingPathComponent("Utilities/Editor.app"),
            bundleIdentifier: "com.example.editor",
            displayName: "Example Editor"
        )
        try makeApp(
            at: root.appendingPathComponent("Utilities/Editor.app/Contents/Helpers/Helper.app"),
            bundleIdentifier: "com.example.editor.helper",
            displayName: "Editor Helper"
        )
        try makeApp(
            at: root.appendingPathComponent(".Hidden.app"),
            bundleIdentifier: "com.example.hidden",
            displayName: "Hidden"
        )

        let results = InstalledAppDiscovery.discover(in: [root])

        #expect(results.count == 1)
        #expect(results.first?.bundleIdentifier == "com.example.editor")
        #expect(results.first?.name == "Example Editor")
        #expect(results.first?.isRunning == false)
    }

    @Test("deduplicates matching bundle identifiers across search roots")
    func deduplicatesByBundleIdentifier() throws {
        let firstRoot = try makeTemporaryDirectory()
        let secondRoot = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }

        try makeApp(
            at: firstRoot.appendingPathComponent("First.app"),
            bundleIdentifier: "com.example.same",
            displayName: "First Copy"
        )
        try makeApp(
            at: secondRoot.appendingPathComponent("Second.app"),
            bundleIdentifier: "com.example.same",
            displayName: "Second Copy"
        )

        let results = InstalledAppDiscovery.discover(in: [firstRoot, secondRoot])

        #expect(results.count == 1)
        #expect(results.first?.name == "First Copy")
    }

    @Test("ignores directories that are not readable app bundles")
    func ignoresInvalidBundles() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("NotAnApp.app"),
            withIntermediateDirectories: true
        )

        #expect(InstalledAppDiscovery.discover(in: [root]).isEmpty)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstalledAppDiscovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeApp(at url: URL, bundleIdentifier: String, displayName: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleDisplayName": displayName,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }
}
