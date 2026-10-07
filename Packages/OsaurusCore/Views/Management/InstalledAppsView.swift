//
//  InstalledAppsView.swift
//  OsaurusCore
//
//  A searchable local directory of installed macOS applications, with native
//  Osaurus integration labels, permission readiness, and launch actions.
//

import AppKit
import SwiftUI

private enum InstalledAppsFilter: String, CaseIterable, Identifiable {
    case all
    case running
    case native

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: L("All")
        case .running: L("Running")
        case .native: L("Built-in")
        }
    }
}

struct InstalledAppsView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var permissionService = SystemPermissionService.shared
    @StateObject private var catalog = InstalledAppCatalog()

    @State private var hasAppeared = false
    @State private var searchText = ""
    @State private var selectedFilter: InstalledAppsFilter = .all
    @State private var launchError: String?

    private var theme: ThemeProtocol { themeManager.currentTheme }

    private var filteredApps: [InstalledMacApp] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return catalog.apps.filter { app in
            let matchesFilter: Bool
            switch selectedFilter {
            case .all: matchesFilter = true
            case .running: matchesFilter = app.isRunning
            case .native: matchesFilter = app.nativeApp != nil
            }
            guard matchesFilter else { return false }
            guard !query.isEmpty else { return true }
            return app.name.localizedCaseInsensitiveContains(query)
                || app.bundleIdentifier?.localizedCaseInsensitiveContains(query) == true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ManagerHeaderWithActions(
                title: L("Installed Apps"),
                subtitle: L("Browse Mac apps and see how Osaurus can work with them."),
                count: catalog.apps.count
            ) {
                HeaderSecondaryButton(L("Agents"), icon: "person.2") {
                    ManagementStateManager.shared.selectedTab = .agents
                }
                HeaderSecondaryButton(
                    catalog.isRefreshing ? L("Refreshing") : L("Refresh"),
                    icon: "arrow.clockwise"
                ) {
                    Task { await catalog.refresh() }
                }
                .disabled(catalog.isRefreshing)
            }
            .managerHeaderEntrance(hasAppeared: hasAppeared)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    automationAccessCard
                    searchAndFilters

                    if !catalog.hasLoaded || catalog.isRefreshing && catalog.apps.isEmpty {
                        ProgressView(L("Finding installed apps…"))
                            .frame(maxWidth: .infinity, minHeight: 180)
                    } else if filteredApps.isEmpty {
                        emptyState
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 320), spacing: 12)],
                            alignment: .leading,
                            spacing: 12
                        ) {
                            ForEach(filteredApps) { app in
                                InstalledAppCard(app: app) {
                                    open(app)
                                }
                            }
                        }
                    }

                    Text(
                        "App discovery reads bundle names and identifiers from common Mac application folders. It does not read app documents or data. Apps installed in other locations may not appear yet.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
            .opacity(hasAppeared ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, theme)
        .onAppear {
            permissionService.refreshAllPermissions()
            withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
                hasAppeared = true
            }
        }
        .task {
            await catalog.refresh()
        }
        .alert(
            L("Couldn't Open App"),
            isPresented: Binding(
                get: { launchError != nil },
                set: { if !$0 { launchError = nil } }
            )
        ) {
            Button(L("OK"), role: .cancel) {}
        } message: {
            Text(launchError ?? "")
        }
    }

    private var automationAccessCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .foregroundColor(theme.accentColor)
                Text("Automation access", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Button(L("Manage Permissions")) {
                    ManagementStateManager.shared.selectedTab = .permissions
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.accentColor)
            }

            HStack(spacing: 12) {
                PermissionReadinessPill(
                    title: L("Accessibility"),
                    detail: L("UI control"),
                    isGranted: permissionService.permissionStates[.accessibility],
                    theme: theme
                )
                PermissionReadinessPill(
                    title: L("Screen Recording"),
                    detail: L("Screenshots"),
                    isGranted: permissionService.permissionStates[.screenRecording],
                    theme: theme
                )
            }

            Text(
                "Accessibility supports UI automation; Screen Recording is used for screenshot-based control. Apple Events access is managed by macOS per target app and may prompt the first time an agent uses it.",
                bundle: .module
            )
            .font(.system(size: 11))
            .foregroundColor(theme.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }

    private var searchAndFilters: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(theme.tertiaryText)
                TextField(L("Search apps or bundle IDs"), text: $searchText)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("installed-apps.search")
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(theme.inputBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(theme.inputBorder, lineWidth: 1)
                    )
            )

            Picker(L("Show"), selection: $selectedFilter) {
                ForEach(InstalledAppsFilter.allCases) { filter in
                    Text(LocalizedStringKey(filter.title), bundle: .module).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 300)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: searchText.isEmpty ? "square.grid.2x2" : "magnifyingglass")
                .font(.system(size: 28))
                .foregroundColor(theme.tertiaryText)
            Text(searchText.isEmpty ? L("No apps found") : L("No matching apps"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(theme.primaryText)
            Text(
                searchText.isEmpty
                    ? L("Refresh to scan the standard Mac application folders.")
                    : L("Try a different name or bundle identifier.")
            )
            .font(.system(size: 12))
            .foregroundColor(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
        )
    }

    private func open(_ app: InstalledMacApp) {
        Task { @MainActor in
            do {
                _ = try await NSWorkspace.shared.openApplication(
                    at: app.bundleURL,
                    configuration: NSWorkspace.OpenConfiguration()
                )
                try? await Task.sleep(nanoseconds: 350_000_000)
                catalog.refreshRunningState()
            } catch {
                launchError = error.localizedDescription
            }
        }
    }
}

private struct PermissionReadinessPill: View {
    let title: String
    let detail: String
    let isGranted: Bool?
    let theme: ThemeProtocol

    private var status: String {
        guard let isGranted else { return L("Checking") }
        return isGranted ? L("Ready") : L("Needs permission")
    }

    private var statusColor: Color {
        guard let isGranted else { return theme.secondaryText }
        return isGranted ? theme.successColor : theme.warningColor
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: isGranted == true ? "checkmark.circle.fill" : "circle")
                .foregroundColor(statusColor)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title), bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.primaryText)
                Text("\(status) · \(detail)", bundle: .module)
                    .font(.system(size: 10))
                    .foregroundColor(statusColor)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(theme.tertiaryBackground.opacity(0.7))
        )
    }
}

private struct InstalledAppCard: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var permissionService = SystemPermissionService.shared

    let app: InstalledMacApp
    let open: () -> Void

    private var integrationTitle: String {
        if let nativeApp = app.nativeApp {
            return L("\(nativeApp.displayName) built-in tools")
        }
        return L("AppleScript / UI automation")
    }

    private var integrationDetail: String {
        if app.nativeApp != nil {
            return L("Enable this app in an agent's Tools settings.")
        }
        return L("Available when an agent has the relevant capability and macOS access.")
    }

    private var permissionSummary: String? {
        guard let nativeApp = app.nativeApp else { return nil }
        guard !nativeApp.systemPermissions.isEmpty else {
            return L("No additional macOS permission required.")
        }
        return nativeApp.systemPermissions
            .map(permissionStatus)
            .joined(separator: " · ")
    }

    private func permissionStatus(_ permission: SystemPermission) -> String {
        if permission.isAutomationBased {
            if permissionService.permissionStates[permission] == true {
                return L("\(permission.displayName): Granted")
            }
            return L("\(permission.displayName): Managed by macOS")
        }
        guard let isGranted = permissionService.permissionStates[permission] else {
            return L("\(permission.displayName): Checking")
        }
        return isGranted
            ? L("\(permission.displayName): Granted")
            : L("\(permission.displayName): Needs permission")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 11) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.bundleURL.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 42, height: 42)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(app.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)
                        if app.isRunning {
                            Text("Running", bundle: .module)
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(theme.successColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(theme.successColor.opacity(0.12)))
                        }
                    }
                    Text(app.bundleIdentifier ?? app.bundleURL.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 4)
                Button(action: open) {
                    Label(L("Open"), systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(Text(localized: "Launch this app"))
            }

            Divider()
                .overlay(theme.cardBorder)

            VStack(alignment: .leading, spacing: 3) {
                Text(LocalizedStringKey(integrationTitle), bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.primaryText)
                Text(LocalizedStringKey(integrationDetail), bundle: .module)
                    .font(.system(size: 10))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let permissionSummary {
                    Text(LocalizedStringKey(permissionSummary), bundle: .module)
                        .font(.system(size: 10))
                        .foregroundColor(theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(theme.cardBorder, lineWidth: 1)
                )
        )
    }
}
