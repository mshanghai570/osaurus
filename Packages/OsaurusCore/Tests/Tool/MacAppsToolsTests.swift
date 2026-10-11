//
//  MacAppsToolsTests.swift
//  osaurusTests
//
//  Hermetic coverage for `mac_apps` and `edit_app_file`: both tools run
//  against a synthetic `.app` bundle in a temp directory (injected via
//  `customRoots`), so the tests never touch the real `/Applications` or
//  depend on what is installed on the machine.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
struct MacAppsToolsTests {

    // MARK: Fixture

    private struct Fixture {
        let root: String
        let bundlePath: String

        static func make() throws -> Fixture {
            let root = NSTemporaryDirectory() + "/mac-apps-tests-\(UUID().uuidString)"
            let bundle = root + "/Fixture.app"
            let contents = bundle + "/Contents"
            let resources = contents + "/Resources"
            try FileManager.default.createDirectory(
                atPath: contents + "/MacOS", withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                atPath: resources, withIntermediateDirectories: true)

            let info: [String: Any] = [
                "CFBundleIdentifier": "ai.osaurus.fixture",
                "CFBundleName": "Fixture",
                "CFBundleShortVersionString": "1.2.3",
                "CFBundleVersion": "17",
                "CFBundleExecutable": "Fixture",
            ]
            let infoData = try PropertyListSerialization.data(
                fromPropertyList: info, format: .xml, options: 0)
            try infoData.write(to: URL(fileURLWithPath: contents + "/Info.plist"))

            try "welcome = Hello;\nfarewell = Goodbye;\n".write(
                toFile: resources + "/Localizable.strings",
                atomically: true, encoding: .utf8)

            // A fake Mach-O: little-endian MH_MAGIC_64 head.
            let machO = Data([0xCF, 0xFA, 0xED, 0xFE]) + Data(repeating: 0x00, count: 64)
            try machO.write(to: URL(fileURLWithPath: contents + "/MacOS/Fixture.bin"))

            return Fixture(root: root, bundlePath: bundle)
        }

        func remove() {
            try? FileManager.default.removeItem(atPath: root)
        }
    }

    private func decode(_ json: String) throws -> [String: Any] {
        let data = try #require(json.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: mac_apps

    @Test
    func listFindsAppWithMetadata() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let tool = MacAppsTool(customRoots: [fixture.root])

        let dict = try decode(
            try await tool.execute(argumentsJSON: #"{"action": "list"}"#))

        #expect(dict["ok"] as? Bool == true)
        let result = try #require(dict["result"] as? [String: Any])
        let apps = try #require(result["apps"] as? [[String: Any]])
        let app = try #require(apps.first { ($0["bundle_id"] as? String) == "ai.osaurus.fixture" })
        #expect(app["version"] as? String == "1.2.3")
        #expect(app["path"] as? String == fixture.bundlePath)
        #expect(app["is_system"] as? Bool == false)
    }

    @Test
    func listQueryFiltersByName() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let tool = MacAppsTool(customRoots: [fixture.root])

        let dict = try decode(
            try await tool.execute(
                argumentsJSON: #"{"action": "list", "query": "does-not-exist"}"#))
        let result = try #require(dict["result"] as? [String: Any])
        let count = try #require(result["count"] as? Int)
        #expect(count == 0)
    }

    @Test
    func inspectDumpsInfoPlist() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let tool = MacAppsTool(customRoots: [fixture.root])

        let dict = try decode(
            try await tool.execute(argumentsJSON: #"{"action": "inspect", "app": "Fixture"}"#))
        #expect(dict["ok"] as? Bool == true)
        let result = try #require(dict["result"] as? [String: Any])
        #expect(result["bundle_id"] as? String == "ai.osaurus.fixture")
        #expect(result["build"] as? String == "17")
        let info = try #require(result["info_plist"] as? [String: Any])
        #expect(info["CFBundleExecutable"] as? String == "Fixture")
    }

    @Test
    func browseListsBundleContents() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let tool = MacAppsTool(customRoots: [fixture.root])

        let dict = try decode(
            try await tool.execute(
                argumentsJSON: #"{"action": "browse", "app": "Fixture", "path": "Contents"}"#))
        #expect(dict["ok"] as? Bool == true)
        let result = try #require(dict["result"] as? [String: Any])
        #expect(result["kind"] as? String == "listing")
        let entries = try #require(result["entries"] as? [[String: Any]])
        let names = entries.compactMap { $0["name"] as? String }
        #expect(names.contains("Info.plist"))
    }

    @Test
    func readPlistRendersJSON() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let tool = MacAppsTool(customRoots: [fixture.root])

        let dict = try decode(
            try await tool.execute(
                argumentsJSON:
                    #"{"action": "read", "app": "Fixture", "path": "Contents/Info.plist"}"#))
        #expect(dict["ok"] as? Bool == true)
        let result = try #require(dict["result"] as? [String: Any])
        #expect(result["format"] as? String == "plist-xml")
        let content = try #require(result["content"] as? String)
        #expect(content.contains("ai.osaurus.fixture"))
    }

    @Test
    func readStringsFileAsText() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let tool = MacAppsTool(customRoots: [fixture.root])

        let dict = try decode(
            try await tool.execute(
                argumentsJSON:
                    #"{"action": "read", "app": "Fixture", "path": "Contents/Resources/Localizable.strings"}"#
            ))
        #expect(dict["ok"] as? Bool == true)
        let result = try #require(dict["result"] as? [String: Any])
        #expect(result["format"] as? String == "text")
        #expect((result["content"] as? String)?.contains("Goodbye") == true)
    }

    @Test
    func readRefusesBinaryFile() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let tool = MacAppsTool(customRoots: [fixture.root])

        let dict = try decode(
            try await tool.execute(
                argumentsJSON:
                    #"{"action": "read", "app": "Fixture", "path": "Contents/MacOS/Fixture.bin"}"#
            ))
        #expect(dict["ok"] as? Bool == false)
        #expect(dict["kind"] as? String == "execution_error")
        let message = try #require(dict["message"] as? String)
        #expect(message.contains("binary"))
    }

    @Test
    func pathEscapeIsRefused() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let tool = MacAppsTool(customRoots: [fixture.root])

        let dict = try decode(
            try await tool.execute(
                argumentsJSON:
                    #"{"action": "read", "app": "Fixture", "path": "../../etc/passwd"}"#))
        #expect(dict["ok"] as? Bool == false)
        #expect(dict["kind"] as? String == "invalid_args")
    }

    @Test
    func unknownAppIsNotFound() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let tool = MacAppsTool(customRoots: [fixture.root])

        let dict = try decode(
            try await tool.execute(argumentsJSON: #"{"action": "inspect", "app": "Nope"}"#))
        #expect(dict["ok"] as? Bool == false)
        #expect(dict["kind"] as? String == "not_found")
    }

    // MARK: edit_app_file

    @Test
    func editAppliesChangeAndWritesBackup() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let tool = MacAppsEditTool(customRoots: [fixture.root])
        let file = "Contents/Resources/Localizable.strings"
        let arguments =
            #"{"app": "Fixture", "file": "\#(file)", "edits": [{"find": "Hello", "replace": "Howdy"}], "rationale": "user prefers Howdy"}"#

        let dict = try decode(try await tool.execute(argumentsJSON: arguments))
        #expect(dict["ok"] as? Bool == true)
        let result = try #require(dict["result"] as? [String: Any])
        let text = try #require(result["text"] as? String)
        #expect(text.contains(".osaurus-bak"))

        let edited = try String(
            contentsOfFile: fixture.bundlePath + "/" + file, encoding: .utf8)
        #expect(edited.contains("Howdy"))
        #expect(!edited.contains("Hello"))
        let backup = try String(
            contentsOfFile: fixture.bundlePath + "/" + file + ".osaurus-bak", encoding: .utf8)
        #expect(backup.contains("Hello"))
    }

    @Test
    func editRefusesNonMatchingFind() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let tool = MacAppsEditTool(customRoots: [fixture.root])

        let dict = try decode(
            try await tool.execute(
                argumentsJSON:
                    #"{"app": "Fixture", "file": "Contents/Resources/Localizable.strings", "edits": [{"find": "absent-text", "replace": "x"}]}"#
            ))
        #expect(dict["ok"] as? Bool == false)
        #expect(dict["kind"] as? String == "invalid_args")
        #expect(dict["retryable"] as? Bool == true)
        // Nothing was written.
        let original = try String(
            contentsOfFile: fixture.bundlePath + "/Contents/Resources/Localizable.strings",
            encoding: .utf8)
        #expect(original.contains("Hello"))
    }

    @Test
    func editRefusesExecutableDirectory() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let tool = MacAppsEditTool(customRoots: [fixture.root])

        let dict = try decode(
            try await tool.execute(
                argumentsJSON:
                    #"{"app": "Fixture", "file": "Contents/MacOS/Fixture.bin", "edits": [{"find": "x", "replace": "y"}]}"#
            ))
        #expect(dict["ok"] as? Bool == false)
        #expect(dict["kind"] as? String == "invalid_args")
        let message = try #require(dict["message"] as? String)
        #expect(message.contains("Contents/MacOS"))
    }

    @Test
    func systemBundlesAreClassifiedReadOnly() {
        // System refusal is by path prefix; assert the policy directly
        // through the resolver, since a synthetic /System path is not
        // constructable in the test sandbox.
        #expect(MacAppBundleResolver.isSystemBundle("/System/Applications/Safari.app"))
        #expect(MacAppBundleResolver.isSystemBundle("/Library/Apple/Safari.app"))
        #expect(!MacAppBundleResolver.isSystemBundle("/Applications/Safari.app"))
    }

    @Test
    func applyEditsEnforcesUniqueMatch() {
        let edits = [
            MacAppsEditTool.PendingEdit(find: "a", replace: "b", all: false),
        ]
        #expect(MacAppsEditTool.applyEdits(edits, to: "cat") == "cbt")
        // No match → nil (abort).
        #expect(MacAppsEditTool.applyEdits(edits, to: "dog") == nil)
        // Ambiguous match → nil.
        #expect(MacAppsEditTool.applyEdits(edits, to: "banana") == nil)
        let allEdits = [
            MacAppsEditTool.PendingEdit(find: "a", replace: "b", all: true),
        ]
        #expect(MacAppsEditTool.applyEdits(allEdits, to: "banana") == "bbnbnb")
    }
}
