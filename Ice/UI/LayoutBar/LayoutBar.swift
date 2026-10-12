//
//  LayoutBar.swift
//  Ice
//

import SwiftUI

struct LayoutBar: View {
    private struct Representable: NSViewRepresentable {
        let appState: AppState
        let section: MenuBarSection
        let spacing: CGFloat

        func makeNSView(context: Context) -> LayoutBarScrollView {
            LayoutBarScrollView(appState: appState, section: section, spacing: spacing)
        }

        func updateNSView(_ nsView: LayoutBarScrollView, context: Context) {
            nsView.spacing = spacing
        }
    }

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var imageCache: MenuBarItemImageCache
    @EnvironmentObject var accessibilityItems: AccessibilityMenuBarItems

    let section: MenuBarSection
    let spacing: CGFloat

    private var menuBarManager: MenuBarManager {
        appState.menuBarManager
    }

    private var backgroundShape: some InsettableShape {
        RoundedRectangle(cornerRadius: 9, style: .circular)
    }

    init(section: MenuBarSection, spacing: CGFloat = 0) {
        self.section = section
        self.spacing = spacing
    }

    var body: some View {
        conditionalBody
            .frame(height: 50)
            .frame(maxWidth: .infinity)
            .layoutBarStyle(appState: appState, averageColorInfo: menuBarManager.averageColorInfo)
            .clipShape(backgroundShape)
            .overlay {
                backgroundShape
                    .stroke(.quaternary)
            }
    }

    @ViewBuilder
    private var conditionalBody: some View {
        if ControlItem.isStatusItemHostedByMenuBarAgent {
            AccessibilityLayoutBarContent(section: section.name)
        } else if imageCache.cacheFailed(for: section.name) {
            Text("Unable to display menu bar items")
                .foregroundStyle(menuBarManager.averageColorInfo?.color.brightness ?? 0 > 0.67 ? .black : .white)
        } else {
            Representable(appState: appState, section: section, spacing: spacing)
        }
    }
}

// MARK: - AccessibilityLayoutBarContent

/// The content of a layout bar on macOS 27 and later, where menu bar items are
/// discovered through the accessibility hierarchy and can't be moved by Ice.
private struct AccessibilityLayoutBarContent: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var accessibilityItems: AccessibilityMenuBarItems

    let section: MenuBarSection.Name

    private var items: [AccessibilityMenuBarItem] {
        switch section {
        case .visible: accessibilityItems.visibleItems
        case .hidden: accessibilityItems.hiddenItems
        case .alwaysHidden: []
        }
    }

    private var foregroundColor: Color {
        appState.menuBarManager.averageColorInfo?.color.brightness ?? 0 > 0.67 ? .black : .white
    }

    var body: some View {
        Group {
            if items.isEmpty {
                Text("No menu bar items")
                    .foregroundStyle(foregroundColor)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        ForEach(items) { item in
                            itemView(for: item)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(maxHeight: .infinity)
                }
                .defaultScrollAnchor(.trailing)
            }
        }
        .task {
            // Keep the items up to date while the layout bar is shown.
            while !Task.isCancelled {
                let dividerX = appState.menuBarManager.section(withName: .hidden)?.controlItem.window?.frame.midX
                await accessibilityItems.updateSectionItems(dividerX: dividerX)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder
    private func itemView(for item: AccessibilityMenuBarItem) -> some View {
        if let image = accessibilityItems.images[item.id] {
            Image(nsImage: image)
                .help(item.displayName)
        } else if let icon = item.applicationIcon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
                .frame(width: max(item.frame.width, 26))
                .help(item.displayName)
        }
    }
}
