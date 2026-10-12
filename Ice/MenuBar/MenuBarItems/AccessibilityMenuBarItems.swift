//
//  AccessibilityMenuBarItems.swift
//  Ice
//

import Cocoa
import Combine

// MARK: - AccessibilityMenuBarItem

/// A menu bar item that is discovered through the accessibility hierarchy.
///
/// On macOS 27 and later, menu bar items are hosted by MenuBarAgent and are no
/// longer represented by window server windows, so ``MenuBarItem`` can't find
/// them. Each application's items are still available through its extras menu
/// bar accessibility element.
struct AccessibilityMenuBarItem: Identifiable {
    /// A key that identifies the item across updates.
    let id: String

    /// The accessibility element of the item.
    let element: AXUIElement

    /// The process identifier of the application that owns the item.
    let ownerPID: pid_t

    /// The frame of the item, in Core Graphics coordinates.
    ///
    /// The frames of items that MenuBarAgent moved into its overflow menu
    /// are not updated, but keep the order of the items.
    let frame: CGRect

    /// A name associated with the item that is suited for display to the user.
    let displayName: String

    /// The icon of the application that owns the item.
    let applicationIcon: NSImage?
}

// MARK: - AccessibilityMenuBarItems

/// A source of menu bar items discovered through the accessibility hierarchy,
/// along with images of the items that were captured while they were visible.
@MainActor
final class AccessibilityMenuBarItems: ObservableObject {
    /// The items in the hidden section, ordered from left to right.
    @Published private(set) var hiddenItems = [AccessibilityMenuBarItem]()

    /// Images of items, keyed by item identifier, that were captured the last
    /// time the items were visible in the menu bar.
    @Published private(set) var images = [String: NSImage]()

    /// Returns the current menu bar items of all running applications other
    /// than Ice.
    nonisolated static func getItems() -> [AccessibilityMenuBarItem] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var items = [AccessibilityMenuBarItem]()
        for application in NSWorkspace.shared.runningApplications {
            let pid = application.processIdentifier
            guard pid != ownPID else {
                continue
            }
            let applicationElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(applicationElement, 0.1)
            guard
                let extrasMenuBar: AXUIElement = copyAttribute("AXExtrasMenuBar", of: applicationElement),
                let children: [AXUIElement] = copyAttribute(kAXChildrenAttribute, of: extrasMenuBar)
            else {
                continue
            }
            let bundleIdentifier = application.bundleIdentifier ?? "\(pid)"
            for (index, child) in children.enumerated() {
                // MenuBarAgent wraps its items in hosting view groups.
                var element = child
                if
                    copyAttribute(kAXRoleAttribute, of: child) as String? == (kAXGroupRole as String),
                    let first = (copyAttribute(kAXChildrenAttribute, of: child) as [AXUIElement]?)?.first
                {
                    element = first
                }
                guard
                    let frame = copyFrame(of: element),
                    frame.width > 0,
                    // Items that are not in the menu bar, such as items that
                    // were disallowed by the user, are positioned below it.
                    isInMenuBar(frame)
                else {
                    continue
                }
                let description: String? = copyAttribute(kAXDescriptionAttribute, of: element)
                let identifier: String? = copyAttribute(kAXIdentifierAttribute, of: element)
                items.append(
                    AccessibilityMenuBarItem(
                        id: "\(bundleIdentifier):\(identifier ?? String(index))",
                        element: element,
                        ownerPID: pid,
                        frame: frame,
                        displayName: application.localizedName ?? description ?? bundleIdentifier,
                        applicationIcon: application.icon
                    )
                )
            }
        }
        return items
    }

    /// Updates the items in the hidden section.
    ///
    /// - Parameter dividerX: The x coordinate of the center of the hidden
    ///   section's control item. Items to its left belong to the hidden section.
    func updateHiddenItems(dividerX: CGFloat) async {
        let items = await Task.detached {
            Self.getItems()
        }.value
        hiddenItems = items
            .filter { $0.frame.maxX <= dividerX }
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Captures images of the items in the hidden section while the section
    /// is visible in the menu bar.
    ///
    /// - Parameter dividerX: The x coordinate of the center of the hidden
    ///   section's control item. Items to its left belong to the hidden section.
    func captureHiddenItemImages(dividerX: CGFloat) async {
        let items = await Task.detached {
            Self.getItems()
        }.value
        var images = images
        for item in items where item.frame.maxX <= dividerX {
            guard let image = ScreenCapture.captureScreenBounds(item.frame, option: .bestResolution) else {
                continue
            }
            images[item.id] = NSImage(cgImage: image, size: item.frame.size)
        }
        self.images = images
    }

    /// Opens the given item's menu by performing its press action.
    nonisolated func press(_ item: AccessibilityMenuBarItem) {
        let element = item.element
        Task.detached {
            // The action doesn't return until the menu is closed, so don't
            // wait for it for long.
            AXUIElementSetMessagingTimeout(element, 0.5)
            let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
            if result != .success && result != .cannotComplete {
                Logger.accessibilityItems.error("Failed to press menu bar item: \(result.rawValue)")
            }
        }
    }

    // MARK: Helpers

    private nonisolated static func copyAttribute<T>(_ attribute: String, of element: AXUIElement) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? T
    }

    private nonisolated static func copyFrame(of element: AXUIElement) -> CGRect? {
        var value: CFTypeRef?
        var frame = CGRect.zero
        guard
            AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &value) == .success,
            let value,
            CFGetTypeID(value) == AXValueGetTypeID(),
            AXValueGetValue(value as! AXValue, .cgRect, &frame) // swiftlint:disable:this force_cast
        else {
            return nil
        }
        return frame
    }

    private nonisolated static func isInMenuBar(_ frame: CGRect) -> Bool {
        NSScreen.screens.contains { screen in
            let bounds = CGDisplayBounds(screen.displayID)
            let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
            let menuBarBounds = CGRect(
                x: bounds.minX,
                y: bounds.minY,
                width: bounds.width,
                height: max(menuBarHeight, 24)
            )
            return menuBarBounds.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
    }
}

// MARK: - Logger
private extension Logger {
    static let accessibilityItems = Logger(category: "AccessibilityMenuBarItems")
}
