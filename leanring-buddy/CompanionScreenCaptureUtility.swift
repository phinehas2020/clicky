//
//  CompanionScreenCaptureUtility.swift
//  leanring-buddy
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//

import AppKit
import ScreenCaptureKit

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    let isCursorScreen: Bool
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
    let elementCandidates: [CompanionScreenElementCandidate]
}

struct CompanionScreenElementCandidate {
    let label: String
    let role: String
    let frameInScreenPoints: CGRect
    let centerXInScreenshotPixels: Int
    let centerYInScreenshotPixels: Int
    let accessibilityElement: AXUIElement?
}

@MainActor
enum CompanionScreenCaptureUtility {

    /// Captures all connected displays as JPEG data, labeling each with
    /// whether the user's cursor is on that screen. This gives the AI
    /// full context across multiple monitors.
    static func captureAllScreensAsJPEG() async throws -> [CompanionScreenCapture] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        // Exclude all windows belonging to this app so the AI sees
        // only the user's content, not our overlays or panels.
        let ownBundleIdentifier = Bundle.main.bundleIdentifier
        let ownAppWindows = content.windows.filter { window in
            window.owningApplication?.bundleIdentifier == ownBundleIdentifier
        }

        // Build a lookup from display ID to NSScreen so we can use AppKit-coordinate
        // frames instead of CG-coordinate frames. NSEvent.mouseLocation and NSScreen.frame
        // both use AppKit coordinates (bottom-left origin), while SCDisplay.frame uses
        // Core Graphics coordinates (top-left origin). On multi-display setups, the Y
        // origins differ for secondary displays, which breaks cursor-contains checks
        // and downstream coordinate conversions.
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        // Sort displays so the cursor screen is always first
        let sortedDisplays = content.displays.sorted { displayA, displayB in
            let frameA = nsScreenByDisplayID[displayA.displayID]?.frame ?? displayA.frame
            let frameB = nsScreenByDisplayID[displayB.displayID]?.frame ?? displayB.frame
            let aContainsCursor = frameA.contains(mouseLocation)
            let bContainsCursor = frameB.contains(mouseLocation)
            if aContainsCursor != bContainsCursor { return aContainsCursor }
            return false
        }

        var capturedScreens: [CompanionScreenCapture] = []

        for (displayIndex, display) in sortedDisplays.enumerated() {
            // Use NSScreen.frame (AppKit coordinates, bottom-left origin) so
            // displayFrame is in the same coordinate system as NSEvent.mouseLocation
            // and the overlay window's screenFrame in BlueCursorView.
            let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
            let isCursorScreen = displayFrame.contains(mouseLocation)

            let filter = SCContentFilter(display: display, excludingWindows: ownAppWindows)

            let configuration = SCStreamConfiguration()
            let maxDimension = 1280
            let aspectRatio = CGFloat(display.width) / CGFloat(display.height)
            if display.width >= display.height {
                configuration.width = maxDimension
                configuration.height = Int(CGFloat(maxDimension) / aspectRatio)
            } else {
                configuration.height = maxDimension
                configuration.width = Int(CGFloat(maxDimension) * aspectRatio)
            }

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            let actualScreenshotWidth = cgImage.width
            let actualScreenshotHeight = cgImage.height

            guard let jpegData = NSBitmapImageRep(cgImage: cgImage)
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                continue
            }

            let screenLabel: String
            if sortedDisplays.count == 1 {
                screenLabel = "user's screen (cursor is here)"
            } else if isCursorScreen {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — cursor is on this screen (primary focus)"
            } else {
                screenLabel = "screen \(displayIndex + 1) of \(sortedDisplays.count) — secondary screen"
            }

            capturedScreens.append(CompanionScreenCapture(
                imageData: jpegData,
                label: screenLabel,
                isCursorScreen: isCursorScreen,
                displayWidthInPoints: Int(displayFrame.width),
                displayHeightInPoints: Int(displayFrame.height),
                displayFrame: displayFrame,
                screenshotWidthInPixels: actualScreenshotWidth,
                screenshotHeightInPixels: actualScreenshotHeight,
                elementCandidates: CompanionAccessibilityElementCollector.collectCandidates(
                    in: displayFrame,
                    screenshotWidthInPixels: actualScreenshotWidth,
                    screenshotHeightInPixels: actualScreenshotHeight
                )
            ))
        }

        guard !capturedScreens.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        return capturedScreens
    }
}

private enum CompanionAccessibilityElementCollector {
    private static let maximumVisitedElementCount = 2500
    private static let maximumCandidatesPerScreen = 80
    private static let maximumTraversalDepth = 8
    private static let interactiveRoles = Set([
        kAXButtonRole,
        kAXCheckBoxRole,
        kAXComboBoxRole,
        kAXMenuButtonRole,
        kAXMenuItemRole,
        kAXPopUpButtonRole,
        kAXRadioButtonRole,
        kAXSliderRole,
        kAXTextAreaRole,
        kAXTextFieldRole,
        "AXSearchField"
    ].map { $0 as String })

    @MainActor
    static func collectCandidates(
        in displayFrame: CGRect,
        screenshotWidthInPixels: Int,
        screenshotHeightInPixels: Int
    ) -> [CompanionScreenElementCandidate] {
        guard AXIsProcessTrusted() else {
            return []
        }

        let candidateApplications = NSWorkspace.shared.runningApplications.filter { runningApplication in
            runningApplication.activationPolicy == .regular
                && runningApplication.bundleIdentifier != Bundle.main.bundleIdentifier
        }
        var visitedElementCount = 0
        var candidates: [CompanionScreenElementCandidate] = []

        for runningApplication in candidateApplications {
            guard visitedElementCount < maximumVisitedElementCount else { break }

            let applicationElement = AXUIElementCreateApplication(runningApplication.processIdentifier)
            let rootElements = accessibilityRootElements(for: applicationElement)

            for rootElement in rootElements {
                collectCandidates(
                    from: rootElement,
                    displayFrame: displayFrame,
                    screenshotWidthInPixels: screenshotWidthInPixels,
                    screenshotHeightInPixels: screenshotHeightInPixels,
                    depth: 0,
                    visitedElementCount: &visitedElementCount,
                    candidates: &candidates
                )
            }
        }

        var seenKeys = Set<String>()
        let uniqueCandidates = candidates.filter { candidate in
            let key = "\(candidate.role)|\(candidate.label)|\(Int(candidate.frameInScreenPoints.midX))|\(Int(candidate.frameInScreenPoints.midY))"
            guard !seenKeys.contains(key) else { return false }
            seenKeys.insert(key)
            return true
        }

        return uniqueCandidates
            .sorted { firstCandidate, secondCandidate in
                let firstArea = firstCandidate.frameInScreenPoints.width * firstCandidate.frameInScreenPoints.height
                let secondArea = secondCandidate.frameInScreenPoints.width * secondCandidate.frameInScreenPoints.height
                return firstArea < secondArea
            }
            .prefix(maximumCandidatesPerScreen)
            .map { $0 }
    }

    private static func accessibilityRootElements(for applicationElement: AXUIElement) -> [AXUIElement] {
        var rootElements: [AXUIElement] = []

        var focusedWindowValue: AnyObject?
        if AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        ) == .success,
           let focusedWindow = focusedWindowValue as! AXUIElement? {
            rootElements.append(focusedWindow)
        }

        var windowsValue: AnyObject?
        if AXUIElementCopyAttributeValue(
            applicationElement,
            kAXWindowsAttribute as CFString,
            &windowsValue
        ) == .success,
           let windows = windowsValue as? [AXUIElement] {
            rootElements.append(contentsOf: windows)
        }

        rootElements.append(applicationElement)
        return rootElements
    }

    private static func collectCandidates(
        from element: AXUIElement,
        displayFrame: CGRect,
        screenshotWidthInPixels: Int,
        screenshotHeightInPixels: Int,
        depth: Int,
        visitedElementCount: inout Int,
        candidates: inout [CompanionScreenElementCandidate]
    ) {
        guard depth <= maximumTraversalDepth,
              visitedElementCount < maximumVisitedElementCount else {
            return
        }
        visitedElementCount += 1

        if let candidate = makeCandidate(
            from: element,
            displayFrame: displayFrame,
            screenshotWidthInPixels: screenshotWidthInPixels,
            screenshotHeightInPixels: screenshotHeightInPixels
        ) {
            candidates.append(candidate)
        }

        var childrenValue: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenValue
        ) == .success,
        let children = childrenValue as? [AXUIElement] else {
            return
        }

        for child in children {
            collectCandidates(
                from: child,
                displayFrame: displayFrame,
                screenshotWidthInPixels: screenshotWidthInPixels,
                screenshotHeightInPixels: screenshotHeightInPixels,
                depth: depth + 1,
                visitedElementCount: &visitedElementCount,
                candidates: &candidates
            )
        }
    }

    private static func makeCandidate(
        from element: AXUIElement,
        displayFrame: CGRect,
        screenshotWidthInPixels: Int,
        screenshotHeightInPixels: Int
    ) -> CompanionScreenElementCandidate? {
        guard let role = stringAttribute(kAXRoleAttribute, from: element),
              interactiveRoles.contains(role),
              let label = bestLabel(for: element),
              let frame = frameAttribute(from: element),
              frame.width >= 4,
              frame.height >= 4,
              frame.intersects(displayFrame) else {
            return nil
        }

        let center = CGPoint(x: frame.midX, y: frame.midY)
        let displayLocalX = center.x - displayFrame.origin.x
        let displayLocalY = center.y - displayFrame.origin.y
        let screenshotX = Int(round(displayLocalX * CGFloat(screenshotWidthInPixels) / displayFrame.width))
        let screenshotY = Int(round((displayFrame.height - displayLocalY) * CGFloat(screenshotHeightInPixels) / displayFrame.height))

        guard screenshotX >= 0,
              screenshotX <= screenshotWidthInPixels,
              screenshotY >= 0,
              screenshotY <= screenshotHeightInPixels else {
            return nil
        }

        return CompanionScreenElementCandidate(
            label: label,
            role: role,
            frameInScreenPoints: frame,
            centerXInScreenshotPixels: screenshotX,
            centerYInScreenshotPixels: screenshotY,
            accessibilityElement: element
        )
    }

    private static func bestLabel(for element: AXUIElement) -> String? {
        let labelAttributes = [
            kAXTitleAttribute,
            kAXDescriptionAttribute,
            kAXValueAttribute,
            kAXHelpAttribute,
            kAXIdentifierAttribute
        ]

        for attribute in labelAttributes {
            if let label = stringAttribute(attribute, from: element),
               !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return label.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return nil
    }

    private static func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func frameAttribute(from element: AXUIElement) -> CGRect? {
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }
}
