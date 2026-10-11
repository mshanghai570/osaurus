//
//  InstalledAppsTools.swift
//  OsaurusCore — Tools
//
//  `mac_apps` — see every installed macOS app and read inside its bundle.
//  `edit_app_file` — change a text file inside an app bundle, behind the
//  ordinary `.ask` approval modal, with an automatic backup and honest
//  code-signature guidance.
//
//  Exists because the harness previously had no way to answer "what apps do
//  I have installed?" outside a working folder, and no sanctioned way to
//  change anything inside an app bundle. Asking a model to "fix that one
//  setting in Safari" either fabricated progress or pushed the agent into
//  raw `shell_run` against `/Applications` with no approval surface, no
//  backup, and no awareness that editing a bundle invalidates its code
//  signature. These tools make the read path structured and the write path
//  explicit, reviewed, and recoverable.
//
//  Safety contract (see AGENTS.md — destructive operations):
//    - Reads work everywhere, including /System.
//    - Edits are refused for system bundles and for binaries (Mach-O or any
//      file that is not valid UTF-8). Text-adjacent bundle resources only.
//    - The first edit to a file writes a `.osaurus-bak` copy next to the
//      original, and the tool says where that backup is.
//    - The result never claims the app is "fixed": it states that the code
//      signature no longer validates and names the re-sign command, because
//      a quietly broken signature is exactly the kind of damage an agent
//      would otherwise report as success.
//

import Foundation

// MARK: - Shared bundle resolution

/// Resolver shared by `mac_apps` and `edit_app_file` so both tools see the
/// exact same app universe and cannot drift.
enum MacAppBundleResolver {

    /// Standard locations apps install to. Scanned shallowly (plus one level
    /// of nesting for managers like Setapp that put bundles in a subfolder).
    /// Spotlight/`NSWorkspace` would need extra privacy grants and is not
    /// deterministic across machines; a directory walk is honest and instant.
    static var defaultRoots: [String] {
        var roots = ["/Applications", "/System/Applications", "/System/Library/CoreServices"]
        roots.insert(NSHomeDirectory() + "/Applications", at: 1)
        return roots
    }

    /// Normalize a reference: if it names an existing `.app` path, use it;
    /// otherwise search the roots for a bundle whose name matches
    /// (case-insensitive, `.app` suffix optional), including one level of
    /// nesting. First hit wins; duplicates resolve in root order.
    static func resolve(
        _ reference: String,
        roots: [String]
    ) -> (bundlePath: String, isSystem: Bool)? {
        let fm = FileManager.default
        var candidate = reference
        if candidate.hasPrefix("~") {
            candidate = NSString(string: candidate).expandingTildeInPath
        }
        candidate = (candidate as NSString).standardizingPath
        if candidate.hasSuffix(".app"), fm.fileExists(atPath: candidate) {
            return (candidate, isSystemBundle(candidate))
        }

        let name = reference.lowercased().hasSuffix(".app")
            ? String(reference.dropLast(4))
            : reference
        for root in roots {
            let rootPath = root.hasPrefix("~")
                ? NSString(string: root).expandingTildeInPath : root
            guard let contents = try? fm.contentsOfDirectory(atPath: rootPath) else { continue }
            for entry in contents where entry.lowercased() == "\(name.lowercased()).app" {
                let path = (rootPath as NSString).appendingPathComponent(entry)
                if fm.fileExists(atPath: path) { return (path, isSystemBundle(path)) }
            }
            // One level of nesting (e.g. /Applications/Setapp/Foo.app).
            for entry in contents {
                let sub = (rootPath as NSString).appendingPathComponent(entry)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: sub, isDirectory: &isDir), isDir.boolValue,
                    !entry.hasSuffix(".app"),
                    let nested = try? fm.contentsOfDirectory(atPath: sub)
                else { continue }
                for nestedEntry in nested where nestedEntry.lowercased()
                    == "\(name.lowercased()).app"
                {
                    let path = (sub as NSString).appendingPathComponent(nestedEntry)
                    if fm.fileExists(atPath: path) { return (path, isSystemBundle(path)) }
                }
            }
        }
        return nil
    }

    static func isSystemBundle(_ bundlePath: String) -> Bool {
        bundlePath.hasPrefix("/System/") || bundlePath.hasPrefix("/Library/Apple/")
    }

    /// Bundle metadata for listings and inspect results.
    static func metadata(forBundle bundlePath: String) -> [String: Any] {
        let infoURL = URL(fileURLWithPath: bundlePath)
            .appendingPathComponent("Contents/Info.plist")
        var info: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: infoURL.path),
            let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any]
        {
            info = plist
        }
        let name = (bundlePath as NSString).lastPathComponent
        let base = (name as NSString).deletingPathExtension
        let fm = FileManager.default
        let signaturePath = (bundlePath as NSString)
            .appendingPathComponent("Contents/_CodeSignature/CodeResources")
        var bundleSize = 0
        if let enumerator = fm.enumerator(atPath: bundlePath) {
            for case let file as String in enumerator {
                if let attrs = try? fm.attributesOfItem(
                    atPath: (bundlePath as NSString).appendingPathComponent(file)),
                    let size = attrs[.size] as? Int
                {
                    bundleSize += size
                }
            }
        }
        return [
            "name": (info["CFBundleName"] as? String) ?? base,
            "bundle_name": name,
            "path": bundlePath,
            "bundle_id": info["CFBundleIdentifier"] ?? NSNull(),
            "version": info["CFBundleShortVersionString"] ?? NSNull(),
            "build": info["CFBundleVersion"] ?? NSNull(),
            "executable": info["CFBundleExecutable"] ?? NSNull(),
            "category": info["LSApplicationCategoryType"] ?? NSNull(),
            "minimum_macos": info["LSMinimumSystemVersion"] ?? NSNull(),
            "signed": fm.fileExists(atPath: signaturePath),
            "size_bytes": bundleSize,
            "is_system": isSystemBundle(bundlePath),
        ]
    }
}

// MARK: - mac_apps (read-only)

/// One tool fanned by `action` (same shape as `osaurus_config`): enumerate
/// installed apps, inspect a bundle's Info.plist, browse a bundle directory,
/// or read a text/plist file inside it. Read-only, so it carries no
/// permission modal — the write-side sibling `edit_app_file` does.
final class MacAppsTool: OsaurusTool, @unchecked Sendable {

    let name = "mac_apps"

    let description =
        "See and read the macOS apps installed on this machine. `action:\"list\"` enumerates "
        + "every app bundle (name, path, bundle id, version, size, signed); `action:\"inspect\"` "
        + "dumps one bundle's Info.plist; `action:\"browse\"` lists a directory inside a bundle; "
        + "`action:\"read\"` reads a text or plist file inside a bundle (plists are rendered as "
        + "readable JSON). To CHANGE a file inside an app bundle use `edit_app_file`, which asks "
        + "the user first."

    /// Bundle size walks can be slow on huge bundles; list stays bounded.
    static let defaultListLimit = 100
    static let maxListLimit = 500
    /// Cap a single read so a model cannot pull a 40MB resource into context.
    static let maxReadBytes = 200_000
    /// Cap one directory listing.
    static let maxListingEntries = 500

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "action": .object([
                "type": .string("string"),
                "description": .string(
                    "`list` (enumerate installed apps), `inspect` (one app's Info.plist), "
                        + "`browse` (list a directory inside a bundle), or `read` (read a file "
                        + "inside a bundle)."
                ),
            ]),
            "app": .object([
                "type": .string("string"),
                "description": .string(
                    "App name (\"Safari\", case-insensitive) or `.app` bundle path. Required for "
                        + "`inspect`, `browse`, and `read`."
                ),
            ]),
            "path": .object([
                "type": .string("string"),
                "description": .string(
                    "Bundle-relative path: a directory for `browse` (empty or \"/\" is the bundle "
                        + "root) or a file for `read`, e.g. `Contents/Info.plist`."
                ),
            ]),
            "query": .object([
                "type": .string("string"),
                "description": .string(
                    "Optional case-insensitive filter for `list`, matched against app name and "
                        + "bundle id."
                ),
            ]),
            "limit": .object([
                "type": .string("integer"),
                "description": .string(
                    "Max apps to return from `list`. Default \(defaultListLimit), "
                        + "max \(maxListLimit)."
                ),
            ]),
        ]),
        "required": .array([.string("action")]),
    ])

    let roots: [String]

    init(customRoots: [String]? = nil) {
        roots = customRoots ?? MacAppBundleResolver.defaultRoots
    }

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let actionReq = requireAction(args, allowed: ["list", "inspect", "browse", "read"])
        guard case .value(let action) = actionReq else { return actionReq.failureEnvelope ?? "" }

        switch action {
        case "list": return listApps(args)
        case "inspect": return inspectApp(args)
        case "browse": return browseBundle(args)
        case "read": return readFile(args)
        default:
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`action` must be one of: list, inspect, browse, read.",
                field: "action",
                tool: name
            )
        }
    }

    // MARK: Actions

    private func listApps(_ args: [String: Any]) -> String {
        let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        var limit = Self.defaultListLimit
        if let rawLimit = coerceInt(args["limit"]) {
            guard rawLimit > 0 else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "`limit` must be a positive integer. Got `\(rawLimit)`.",
                    field: "limit",
                    expected: "positive integer",
                    tool: name
                )
            }
            limit = min(rawLimit, Self.maxListLimit)
        }

        let fm = FileManager.default
        var apps: [[String: Any]] = []
        var truncated = false
        for root in roots {
            let rootPath = root.hasPrefix("~")
                ? NSString(string: root).expandingTildeInPath : root
            guard let entries = try? fm.contentsOfDirectory(atPath: rootPath) else { continue }
            for entry in entries.sorted() where entry.hasSuffix(".app") {
                let path = (rootPath as NSString).appendingPathComponent(entry)
                guard fm.fileExists(atPath: path) else { continue }
                let meta = MacAppBundleResolver.metadata(forBundle: path)
                if let query,
                    !"\(meta["name"] ?? "") \(meta["bundle_id"] ?? "")"
                        .lowercased().contains(query)
                {
                    continue
                }
                if apps.count >= limit { truncated = true; break }
                apps.append(meta)
            }
            if truncated { break }
        }
        if apps.isEmpty, query != nil {
            // Keep the schema stable for the model: an empty query result is
            // still an `apps` listing (count 0), not a bare text message.
            return ToolEnvelope.success(
                tool: name,
                result: [
                    "kind": "apps",
                    "apps": [] as [[String: Any]],
                    "count": 0,
                    "truncated": false,
                    "text": "No installed apps match \"\(query!)\".",
                ]
            )
        }
        return ToolEnvelope.success(
            tool: name,
            result: ["kind": "apps", "apps": apps, "count": apps.count, "truncated": truncated]
        )
    }

    private func inspectApp(_ args: [String: Any]) -> String {
        let appReq = requireString(args, "app", expected: "app name or .app path", tool: name)
        guard case .value(let reference) = appReq else { return appReq.failureEnvelope ?? "" }

        guard let (bundlePath, _) = MacAppBundleResolver.resolve(reference, roots: roots) else {
            return ToolEnvelope.failure(
                kind: .notFound,
                message:
                    "No installed app named \"\(reference)\". Call `mac_apps` with "
                    + "`action:\"list\"` to see the exact names.",
                field: "app",
                tool: name,
                retryable: false
            )
        }
        var meta = MacAppBundleResolver.metadata(forBundle: bundlePath)
        // Inspect adds the full Info.plist, sanitized for JSON.
        let infoURL = URL(fileURLWithPath: bundlePath)
            .appendingPathComponent("Contents/Info.plist")
        if let data = FileManager.default.contents(atPath: infoURL.path),
            let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil)
        {
            meta["info_plist"] = Self.jsonSafe(plist)
        }
        return ToolEnvelope.success(tool: name, result: meta)
    }

    private func browseBundle(_ args: [String: Any]) -> String {
        let appReq = requireString(args, "app", expected: "app name or .app path", tool: name)
        guard case .value(let reference) = appReq else { return appReq.failureEnvelope ?? "" }
        let relPath = ((args["path"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
        let rel = relPath == "/" ? "" : relPath

        guard let (bundlePath, _) = MacAppBundleResolver.resolve(reference, roots: roots) else {
            return ToolEnvelope.failure(
                kind: .notFound,
                message:
                    "No installed app named \"\(reference)\". Call `mac_apps` with "
                    + "`action:\"list\"` to see the exact names.",
                field: "app",
                tool: name,
                retryable: false
            )
        }
        guard let dirPath = Self.pathInBundle(bundlePath: bundlePath, relative: rel) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`path` must stay inside the app bundle (no `..` escapes).",
                field: "path",
                expected: "bundle-relative directory path",
                tool: name
            )
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dirPath, isDirectory: &isDir), isDir.boolValue else {
            return ToolEnvelope.failure(
                kind: .notFound,
                message: "No directory at `\(rel)` inside \(bundlePath).",
                field: "path",
                tool: name,
                retryable: false
            )
        }
        guard let entries = try? fm.contentsOfDirectory(atPath: dirPath) else {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Could not read directory \(dirPath) (permissions).",
                tool: name
            )
        }
        var rows: [[String: Any]] = []
        var truncated = false
        for entry in entries.sorted() {
            if rows.count >= Self.maxListingEntries { truncated = true; break }
            let full = (dirPath as NSString).appendingPathComponent(entry)
            var entryIsDir: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &entryIsDir)
            rows.append([
                "name": entry,
                "path": full,
                "type": entryIsDir.boolValue ? "directory" : "file",
            ])
        }
        return ToolEnvelope.listing(
            tool: name,
            path: dirPath,
            entries: rows,
            truncated: truncated
        )
    }

    private func readFile(_ args: [String: Any]) -> String {
        let appReq = requireString(args, "app", expected: "app name or .app path", tool: name)
        guard case .value(let reference) = appReq else { return appReq.failureEnvelope ?? "" }
        let pathReq = requireString(
            args, "path", expected: "bundle-relative file path", tool: name)
        guard case .value(let rel) = pathReq else { return pathReq.failureEnvelope ?? "" }

        guard let (bundlePath, _) = MacAppBundleResolver.resolve(reference, roots: roots) else {
            return ToolEnvelope.failure(
                kind: .notFound,
                message:
                    "No installed app named \"\(reference)\". Call `mac_apps` with "
                    + "`action:\"list\"` to see the exact names.",
                field: "app",
                tool: name,
                retryable: false
            )
        }
        guard let filePath = Self.pathInBundle(bundlePath: bundlePath, relative: rel) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`path` must stay inside the app bundle (no `..` escapes).",
                field: "path",
                expected: "bundle-relative file path",
                tool: name
            )
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: filePath) else {
            return ToolEnvelope.failure(
                kind: .notFound,
                message:
                    "No file at `\(rel)` inside \(bundlePath). Browse the parent first with "
                    + "`action:\"browse\"`.",
                field: "path",
                tool: name,
                retryable: false
            )
        }

        let ext = (filePath as NSString).pathExtension.lowercased()
        if ext == "plist" {
            guard let data = fm.contents(atPath: filePath),
                let plist = try? PropertyListSerialization.propertyList(
                    from: data, options: [], format: nil)
            else {
                return ToolEnvelope.failure(
                    kind: .executionError,
                    message: "Could not parse \(filePath) as a property list.",
                    tool: name
                )
            }
            let safe = Self.jsonSafe(plist)
            guard let json = Self.prettyJSON(safe) else {
                return ToolEnvelope.failure(
                    kind: .executionError,
                    message: "Parsed \(filePath) but could not render it as JSON.",
                    tool: name
                )
            }
            let truncated = json.utf8.count > Self.maxReadBytes
            let text = truncated
                ? String(json.prefix(Self.maxReadBytes)) : json
            return ToolEnvelope.success(
                tool: name,
                result: [
                    "kind": "file", "path": filePath, "format": "plist-xml",
                    "content": text, "truncated": truncated,
                ],
                warnings: truncated ? ["File truncated at \(Self.maxReadBytes) bytes."] : nil
            )
        }

        // Text path: must prove it is text (no NUL bytes, valid UTF-8).
        guard let content = Self.readAsTextIfEligible(filePath) else {
            return ToolEnvelope.failure(
                kind: .executionError,
                message:
                    "\(filePath) is a binary file (Mach-O executable, image, or other non-text "
                    + "resource) and cannot be returned as text. `browse` its directory to find "
                    + "a text resource, or read a `.plist` file which is parsed for you.",
                tool: name,
                retryable: false
            )
        }
        let truncated = content.utf8.count > Self.maxReadBytes
        let text = truncated ? String(content.prefix(Self.maxReadBytes)) : content
        return ToolEnvelope.success(
            tool: name,
            result: [
                "kind": "file", "path": filePath, "format": "text",
                "content": text, "truncated": truncated,
            ],
            warnings: truncated ? ["File truncated at \(Self.maxReadBytes) bytes."] : nil
        )
    }

    // MARK: Path + text helpers (shared with the edit tool)

    /// Resolve `relative` inside `bundlePath`, refusing escapes. Returns nil
    /// when the path normalizes outside the bundle.
    static func pathInBundle(bundlePath: String, relative: String) -> String? {
        let bundle = (bundlePath as NSString).standardizingPath
        let candidate = (bundle as NSString).appendingPathComponent(relative)
        let standardized = (candidate as NSString).standardizingPath
        guard standardized == bundle || standardized.hasPrefix(bundle + "/") else { return nil }
        return standardized
    }

    /// Eligible text read: a file whose head contains no NUL bytes and that
    /// decodes fully as UTF-8. Mach-O and other binaries fail here.
    static func readAsTextIfEligible(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        // Binary probe: any NUL byte in the head means this is Mach-O, an
        // image, or another non-text resource.
        let head = data.prefix(8192)
        guard !head.contains(0), let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    /// Recursively convert a property-list value tree into JSON-serializable
    /// values (Data → base64 string, Date → ISO 8601).
    static func jsonSafe(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]:
            return dict.mapValues { jsonSafe($0) }
        case let array as [Any]:
            return array.map { jsonSafe($0) }
        case let data as Data:
            return data.base64EncodedString()
        case let date as Date:
            let formatter = ISO8601DateFormatter()
            return formatter.string(from: date)
        default:
            return value
        }
    }

    static func prettyJSON(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(
                withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - edit_app_file (write)

/// Change a text file inside an app bundle by find/replace.
///
/// Gated by the ordinary tool-permission modal (`.ask`), with an automatic
/// first-time backup next to the edited file. The result never claims the app
/// is fixed outright: it states plainly that the code signature no longer
/// validates (when the bundle was signed) and names the ad-hoc re-sign
/// command, plus that the app must be relaunched for the change to take
/// effect. System bundles are refused outright — SIP-protected or not,
/// editing the OS's own apps is not a decision an approval card covers.
final class MacAppsEditTool: OsaurusTool, PermissionedTool, @unchecked Sendable {

    let name = "edit_app_file"

    let description =
        "Edit a TEXT file inside an installed macOS app's bundle (e.g. a plist, .strings, "
        + "config or other text resource) by find and replace. Each `find` must match exactly "
        + "once unless you set `all`. The user approves the call before anything is written; the "
        + "first edit to a file saves a `.osaurus-bak` backup next to it. Editing a bundle "
        + "invalidates its code signature — the result explains how to re-sign ad hoc. "
        + "Executables and other binary files are refused; system apps are refused."

    var requirements: [String] { [] }
    var defaultPermissionPolicy: ToolPermissionPolicy { .ask }

    static let maxEditsPerCall = 50
    static let maxFileBytes = 4 * 1024 * 1024

    let roots: [String]

    init(customRoots: [String]? = nil) {
        roots = customRoots ?? MacAppBundleResolver.defaultRoots
    }

    struct PendingEdit {
        var find: String
        var replace: String
        var all: Bool
    }

    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "app": .object([
                "type": .string("string"),
                "description": .string(
                    "App name (case-insensitive) or `.app` bundle path to edit inside."
                ),
            ]),
            "file": .object([
                "type": .string("string"),
                "description": .string(
                    "Bundle-relative path of the file to edit, e.g. "
                        + "`Contents/Resources/Preferences.plist`. Use `mac_apps` with "
                        + "`action:\"read\"` first to see the current content."
                ),
            ]),
            "edits": .object([
                "type": .string("array"),
                "description": .string(
                    "Substitutions applied to the file in order. Send every edit for one file "
                        + "in a single call."
                ),
                "items": .object([
                    "type": .string("object"),
                    "additionalProperties": .bool(false),
                    "properties": .object([
                        "find": .object([
                            "type": .string("string"),
                            "description": .string(
                                "Exact text to look for, including whitespace. Must appear once "
                                    + "unless `all` is true."
                            ),
                        ]),
                        "replace": .object([
                            "type": .string("string"),
                            "description": .string("Text to put in its place. May be empty."),
                        ]),
                        "all": .object([
                            "type": .string("boolean"),
                            "description": .string(
                                "Replace every occurrence instead of a unique match."
                            ),
                        ]),
                    ]),
                    "required": .array([.string("find"), .string("replace")]),
                ]),
            ]),
            "rationale": .object([
                "type": .string("string"),
                "description": .string(
                    "One line on why this app file is changing. Shown to the user in the "
                        + "approval card."
                ),
            ]),
        ]),
        "required": .array([.string("app"), .string("file"), .string("edits")]),
    ])

    func execute(argumentsJSON: String) async throws -> String {
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let appReq = requireString(args, "app", expected: "app name or .app path", tool: name)
        guard case .value(let reference) = appReq else { return appReq.failureEnvelope ?? "" }
        let fileReq = requireString(
            args, "file", expected: "bundle-relative file path", tool: name)
        guard case .value(let rel) = fileReq else { return fileReq.failureEnvelope ?? "" }
        let editsReq = Self.edits(from: args)
        guard case .success(let edits) = editsReq else { return editsReq.failureEnvelope ?? "" }

        guard let (bundlePath, isSystem) = MacAppBundleResolver.resolve(reference, roots: roots)
        else {
            return ToolEnvelope.failure(
                kind: .notFound,
                message:
                    "No installed app named \"\(reference)\". Call `mac_apps` with "
                    + "`action:\"list\"` to see the exact names.",
                field: "app",
                tool: name,
                retryable: false
            )
        }
        guard !isSystem else {
            return ToolEnvelope.failure(
                kind: .rejected,
                message:
                    "\"\(reference)\" is a system app (\(bundlePath)) and cannot be edited. "
                    + "System bundles are managed by macOS.",
                tool: name,
                retryable: false
            )
        }
        guard let filePath = MacAppsTool.pathInBundle(bundlePath: bundlePath, relative: rel) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`file` must stay inside the app bundle (no `..` escapes).",
                field: "file",
                expected: "bundle-relative file path",
                tool: name
            )
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: filePath) else {
            return ToolEnvelope.failure(
                kind: .notFound,
                message:
                    "No file at `\(rel)` inside \(bundlePath). Use `mac_apps` with "
                    + "`action:\"browse\"` to find the right path.",
                field: "file",
                tool: name,
                retryable: false
            )
        }
        // Executables are the highest-blast-radius target here, and a Mach-O
        // find/replace is corruption anyway. Refuse before reading anything.
        if rel.hasPrefix("Contents/MacOS/") {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "`\(rel)` is inside Contents/MacOS (an executable). Binaries cannot be "
                    + "edited by find/replace. Only text resources (plists, strings, config) "
                    + "are editable.",
                field: "file",
                expected: "a text resource path",
                tool: name,
                retryable: false
            )
        }
        guard
            let attributes = try? fm.attributesOfItem(atPath: filePath),
            let size = attributes[.size] as? Int, size <= Self.maxFileBytes
        else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "`\(rel)` is larger than the \(Self.maxFileBytes / (1024 * 1024))MB edit "
                    + "limit.",
                field: "file",
                tool: name,
                retryable: false
            )
        }
        guard let data = fm.contents(atPath: filePath),
            let current = String(data: data, encoding: .utf8)
        else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "`\(rel)` is not a text file (binary, or not valid UTF-8) and cannot be "
                    + "edited by find/replace.",
                field: "file",
                expected: "a UTF-8 text resource",
                tool: name,
                retryable: false
            )
        }

        guard let edited = Self.applyEdits(edits, to: current) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "An edit's `find` did not match exactly once. Nothing was written. Re-read "
                    + "the file with `mac_apps` (`action:\"read\"`), copy the exact text "
                    + "including whitespace, or set `all` to replace every occurrence.",
                field: "edits",
                tool: name,
                retryable: true
            )
        }
        guard edited != current else {
            return ToolEnvelope.success(
                tool: name,
                text: "No change: the edits produced the file `\(rel)` already has. Nothing was written."
            )
        }

        // Backup: first edit only, so repeated edits never overwrite the
        // pristine original the user may want to restore.
        let backupPath = filePath + ".osaurus-bak"
        var backedUp = false
        if !fm.fileExists(atPath: backupPath) {
            backedUp = (try? fm.copyItem(atPath: filePath, toPath: backupPath)) != nil
        }

        do {
            try edited.write(toFile: filePath, atomically: true, encoding: .utf8)
        } catch {
            return ToolEnvelope.failure(
                kind: .executionError,
                message:
                    "Could not write \(filePath): \(error.localizedDescription). If the bundle "
                    + "is read-only, the app may need to be moved to a user-writable location "
                    + "first.",
                tool: name,
                retryable: false
            )
        }

        let applied = edits.count == 1 ? "1 edit" : "\(edits.count) edits"
        var text = "Applied \(applied) to `\(rel)` in \(bundlePath)."
        if backedUp {
            text += "\nBackup of the original saved at `\(backupPath)`."
        } else if fm.fileExists(atPath: backupPath) {
            text += "\nThe existing backup at `\(backupPath)` was left untouched."
        }
        let signaturePath = (bundlePath as NSString)
            .appendingPathComponent("Contents/_CodeSignature/CodeResources")
        if fm.fileExists(atPath: signaturePath) {
            text +=
                "\nThis bundle is signed, and editing it invalidates the code signature. To "
                + "re-sign ad hoc (all local changes): `codesign --force --deep --sign - "
                + "\"\(bundlePath)\"`. If the app misbehaves, restore from the backup and "
                + "re-sign the same way."
        }
        text +=
            "\nThe app must be relaunched for the change to take effect. Confirm what landed "
            + "with `mac_apps` (`action:\"read\"`) before reporting the edit as done."
        return ToolEnvelope.success(tool: name, text: text)
    }

    // MARK: Edits parsing + application

    enum EditsResult {
        case success([PendingEdit])
        case failure(String)

        var failureEnvelope: String? {
            if case .failure(let envelope) = self { return envelope }
            return nil
        }
    }

    static func edits(from args: [String: Any]) -> EditsResult {
        var parsed: [PendingEdit] = []
        if let raw = args["edits"] as? [[String: Any]] {
            for entry in raw {
                guard let find = entry["find"] as? String, !find.isEmpty else {
                    return .failure(
                        ToolEnvelope.failure(
                            kind: .invalidArgs,
                            message: "Every entry in `edits` needs a non-empty `find`.",
                            field: "edits",
                            expected: "array of {find, replace}",
                            tool: "edit_app_file"
                        )
                    )
                }
                parsed.append(
                    PendingEdit(
                        find: find,
                        replace: (entry["replace"] as? String) ?? "",
                        all: (entry["all"] as? Bool) ?? false
                    )
                )
            }
        } else if let find = args["find"] as? String, !find.isEmpty {
            parsed.append(
                PendingEdit(
                    find: find,
                    replace: (args["replace"] as? String) ?? "",
                    all: (args["all"] as? Bool) ?? false
                )
            )
        }
        guard !parsed.isEmpty else {
            return .failure(
                ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "No edits to apply. Pass `edits` as an array of {find, replace}.",
                    field: "edits",
                    expected: "non-empty array of {find, replace}",
                    tool: "edit_app_file"
                )
            )
        }
        guard parsed.count <= maxEditsPerCall else {
            return .failure(
                ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message:
                        "\(parsed.count) edits exceeds the limit of \(maxEditsPerCall). That "
                        + "many changes is a rewrite, not an edit.",
                    field: "edits",
                    expected: "at most \(maxEditsPerCall) edits",
                    tool: "edit_app_file"
                )
            )
        }
        return .success(parsed)
    }

    /// Same semantics as `edit_knowledge`: each edit matches exactly once
    /// unless `all` is set; the first non-matching edit aborts the whole call
    /// with nothing written.
    static func applyEdits(_ edits: [PendingEdit], to content: String) -> String? {
        var result = content
        for edit in edits {
            if edit.all {
                guard result.contains(edit.find) else { return nil }
                result = result.replacingOccurrences(of: edit.find, with: edit.replace)
            } else {
                guard let range = result.range(of: edit.find) else { return nil }
                let second = result[range.upperBound...].range(of: edit.find)
                guard second == nil else { return nil }
                result.replaceSubrange(range, with: edit.replace)
            }
        }
        return result
    }
}
