//
//  InstalledAppCatalog.swift
//  OsaurusCore
//
//  Local discovery of macOS application bundles for the Installed Apps
//  directory. Discovery reads bundle metadata only; it does not inspect app
//  documents, databases, or other user content.
//

import AppKit
import Combine
import Foundation

struct InstalledMacApp: Identifiable, Hashable, Sendable {
    let bundleIdentifier: String?
    let name: String
    let bundleURL: URL
    var isRunning: Bool

    var id: String {
        bundleIdentifier ?? bundleURL.standardizedFileURL.path
    }

    var nativeApp: AppleApp? {
        guard let bundleIdentifier else { return nil }
        return AppleApp.app(forBundleIdentifier: bundleIdentifier)
    }
}

enum InstalledAppDiscovery {
    static func defaultSearchRoots(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [
            homeDirectory.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app", isDirectory: true),
        ]
    }

    static func discover(
        in roots: [URL],
        fileManager: FileManager = .default
    ) -> [InstalledMacApp] {
        var appsByIdentity: [String: InstalledMacApp] = [:]

        func insert(_ appURL: URL) {
            guard let app = readAppBundle(at: appURL, fileManager: fileManager) else { return }
            let identity = app.bundleIdentifier ?? app.bundleURL.standardizedFileURL.path
            guard appsByIdentity[identity] == nil else { return }
            appsByIdentity[identity] = app
        }

        for root in roots {
            if root.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                insert(root)
                continue
            }
            guard fileManager.fileExists(atPath: root.path),
                let enumerator = fileManager.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            else {
                continue
            }

            while let candidate = enumerator.nextObject() as? URL {
                guard candidate.pathExtension.caseInsensitiveCompare("app") == .orderedSame else { continue }
                // An .app is a package. Don't report helper apps nested in a
                // parent application's Contents directory as separately
                // installed applications.
                enumerator.skipDescendants()
                insert(candidate)
            }
        }

        return appsByIdentity.values.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            if order == .orderedSame {
                return $0.bundleURL.path.localizedStandardCompare($1.bundleURL.path) == .orderedAscending
            }
            return order == .orderedAscending
        }
    }

    private static func readAppBundle(at url: URL, fileManager: FileManager) -> InstalledMacApp? {
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
            let propertyList = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let info = propertyList as? [String: Any]
        else {
            return nil
        }

        let bundleIdentifier = (info["CFBundleIdentifier"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let usableIdentifier = bundleIdentifier?.isEmpty == false ? bundleIdentifier : nil
        let bundleName = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let name = bundleName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, fileManager.fileExists(atPath: url.path) else { return nil }

        return InstalledMacApp(
            bundleIdentifier: usableIdentifier,
            name: name,
            bundleURL: url.standardizedFileURL,
            isRunning: false
        )
    }
}

@MainActor
final class InstalledAppCatalog: ObservableObject {
    @Published private(set) var apps: [InstalledMacApp] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var hasLoaded = false

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        let roots = InstalledAppDiscovery.defaultSearchRoots()
        let discovered = await Task.detached(priority: .utility) {
            InstalledAppDiscovery.discover(in: roots)
        }.value
        let runningBundleIdentifiers = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )
        apps = discovered.map { app in
            InstalledMacApp(
                bundleIdentifier: app.bundleIdentifier,
                name: app.name,
                bundleURL: app.bundleURL,
                isRunning: app.bundleIdentifier.map(runningBundleIdentifiers.contains) ?? false
            )
        }
        hasLoaded = true
        isRefreshing = false
    }

    func refreshRunningState() {
        let runningBundleIdentifiers = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )
        apps = apps.map { app in
            var refreshed = app
            refreshed.isRunning = app.bundleIdentifier.map(runningBundleIdentifiers.contains) ?? false
            return refreshed
        }
    }
}
