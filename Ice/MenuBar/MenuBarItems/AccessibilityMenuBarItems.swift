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

    /// The items in the visible section, ordered from left to right.
    @Published private(set) var visibleItems = [AccessibilityMenuBarItem]()

    /// Images of items, keyed by item identifier, that were captured the last
    /// time the items were visible in the menu bar.
    @Published private(set) var images = [String: NSImage]()

    /// The horizontal positions of items, keyed by item identifier, at the
    /// time their images were captured, used to order the hidden items.
    ///
    /// The frames of items in MenuBarAgent's overflow menu are not updated,
    /// so the frames of items that were hidden at different times can't be
    /// compared with each other.
    private var positions = Defaults.dictionary(forKey: .accessibilityItemPositions) as? [String: CGFloat] ?? [:]

    /// The directory where captured images are stored between launches.
    private let imagesDirectory: URL? = {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return caches
            .appendingPathComponent(Constants.bundleIdentifier, isDirectory: true)
            .appendingPathComponent("MenuBarItemImages", isDirectory: true)
    }()

    init() {
        loadImages()
    }

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

    /// Updates the items in the hidden and visible sections.
    ///
    /// The frames of items in MenuBarAgent's overflow menu are not updated, so
    /// they can't be used to tell whether an item is hidden. Instead, an item
    /// is hidden if it isn't the element at the center of its frame.
    ///
    /// - Parameter dividerX: The x coordinate of the center of the hidden
    ///   section's control item. Items that are shown to its left belong to
    ///   the hidden section, i.e. while the hidden section is shown.
    func updateSectionItems(dividerX: CGFloat?) async {
        let classifiedItems = await Task.detached {
            Self.getItems().map { item in (item, Self.isVisible(item)) }
        }.value
        var hiddenItems = [AccessibilityMenuBarItem]()
        var visibleItems = [AccessibilityMenuBarItem]()
        for (item, isVisible) in classifiedItems {
            if !isVisible {
                hiddenItems.append(item)
            } else if let dividerX, item.frame.midX < dividerX {
                hiddenItems.append(item)
            } else {
                visibleItems.append(item)
            }
        }
        self.hiddenItems = hiddenItems.sorted { lhs, rhs in
            (positions[lhs.id] ?? lhs.frame.minX) < (positions[rhs.id] ?? rhs.frame.minX)
        }
        self.visibleItems = visibleItems.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Returns a Boolean value that indicates whether the given item is the
    /// element that is shown at the center of its frame.
    private nonisolated static func isVisible(_ item: AccessibilityMenuBarItem) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, 0.1)
        var element: AXUIElement?
        guard
            AXUIElementCopyElementAtPosition(systemWide, Float(item.frame.midX), Float(item.frame.midY), &element) == .success,
            var current = element
        else {
            return false
        }
        // The element at the location may be a descendant of the item.
        for _ in 0..<3 {
            if CFEqual(current, item.element) {
                return true
            }
            guard let parent: AXUIElement = copyAttribute(kAXParentAttribute, of: current) else {
                return false
            }
            current = parent
        }
        return false
    }

    /// Captures images of all items that are currently visible in the menu bar.
    ///
    /// Call this before Ice hides any items, i.e. when the app launches, so
    /// that the Ice Bar can display the items without first showing them in
    /// the menu bar.
    func captureVisibleItemImages() {
        // Skip items that are still moving into place, i.e. when Ice is opened
        // right after it was closed and MenuBarAgent is still moving the items
        // back out of its overflow menu.
        let firstItems = Self.getItems()
        Thread.sleep(forTimeInterval: 0.25)
        let items = Self.getItems().filter { item in
            firstItems.contains { $0.id == item.id && $0.frame == item.frame }
        }
        captureImages(of: items)
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
        captureImages(of: items.filter { $0.frame.maxX <= dividerX })
    }

    /// Captures and stores images of the given items.
    ///
    /// Items that MenuBarAgent moved into its overflow menu keep outdated
    /// frames, and are skipped.
    private func captureImages(of items: [AccessibilityMenuBarItem]) {
        guard ScreenCapture.cachedCheckPermissions() else {
            return
        }
        var images = images
        var positions = positions
        for item in items {
            let overlapsOtherItem = items.contains { other in
                other.id != item.id && other.frame.insetBy(dx: 1, dy: 1).intersects(item.frame)
            }
            guard
                !overlapsOtherItem,
                // Frames of items in the overflow menu can be outdated without
                // overlapping other items, so make sure the item is shown there.
                Self.isVisible(item),
                let cgImage = ScreenCapture.captureScreenBounds(item.frame, option: .bestResolution)
            else {
                continue
            }
            let image = NSImage(cgImage: cgImage, size: item.frame.size)
            images[item.id] = image
            positions[item.id] = item.frame.minX
            saveImage(cgImage, size: item.frame.size, for: item.id)
        }
        self.images = images
        self.positions = positions
        Defaults.set(positions, forKey: .accessibilityItemPositions)
    }

    // MARK: Image Storage

    private func imageURL(for id: String) -> URL? {
        let fileName = id.replacingOccurrences(of: "/", with: "_") + ".png"
        return imagesDirectory?.appendingPathComponent(fileName)
    }

    private func saveImage(_ image: CGImage, size: CGSize, for id: String) {
        guard
            let imagesDirectory,
            let url = imageURL(for: id)
        else {
            return
        }
        let rep = NSBitmapImageRep(cgImage: image)
        // Setting the size in points stores the resolution of the image.
        rep.size = size
        do {
            try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
            try rep.representation(using: .png, properties: [:])?.write(to: url)
        } catch {
            Logger.accessibilityItems.error("Failed to save menu bar item image: \(error)")
        }
    }

    private func loadImages() {
        guard
            let imagesDirectory,
            let urls = try? FileManager.default.contentsOfDirectory(at: imagesDirectory, includingPropertiesForKeys: nil)
        else {
            return
        }
        var images = [String: NSImage]()
        for url in urls where url.pathExtension == "png" {
            let id = url.deletingPathExtension().lastPathComponent
            images[id] = NSImage(contentsOf: url)
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
