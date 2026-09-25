// VirtualDisplay.swift — a virtual monitor via the private CGVirtualDisplay API.
//
// Same approach as DeskPad / BetterDisplay: WindowServer treats the
// display as a real extended desktop, so a viewer can stream it to an
// external monitor. The display lives exactly as long as the
// `VirtualDisplay` object; releasing it removes the display.
//
// The private classes are declared in CGVirtualDisplayPrivate.h
// (weak-imported). Always check `VirtualDisplay.isSupported` first.

import Foundation
import CoreGraphics

/// A resolution the virtual display can be created at, in points.
enum VirtualDisplayPreset: String, CaseIterable, Identifiable {
    case p1080 = "1920x1080"
    case p1200 = "1920x1200"
    case p1440 = "2560x1440"
    case p2160 = "3840x2160"

    var id: String { rawValue }

    var width: Int {
        switch self {
        case .p1080, .p1200: return 1920
        case .p1440: return 2560
        case .p2160: return 3840
        }
    }

    var height: Int {
        switch self {
        case .p1080: return 1080
        case .p1200: return 1200
        case .p1440: return 1440
        case .p2160: return 2160
        }
    }

    var label: String { "\(width) × \(height)" }
}

struct VirtualDisplayConfig: Equatable {
    var preset: VirtualDisplayPreset
    var hiDPI: Bool
    var refreshRate: Double = 60

    /// Backing-store scale: HiDPI renders 2 pixels per point.
    var scale: Int { hiDPI ? 2 : 1 }
}

enum VirtualDisplayError: LocalizedError {
    case unsupported
    case createFailed
    case applyFailed

    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "Virtual display unavailable: this macOS lacks the private CGVirtualDisplay API"
        case .createFailed:
            return "Virtual display could not be created"
        case .applyFailed:
            return "Virtual display rejected the requested mode"
        }
    }
}

@MainActor
final class VirtualDisplay {
    static let displayName = "FastPort Display"

    /// True when all four private classes exist at runtime.
    static var isSupported: Bool {
        ["CGVirtualDisplay", "CGVirtualDisplayDescriptor",
         "CGVirtualDisplaySettings", "CGVirtualDisplayMode"]
            .allSatisfy { NSClassFromString($0) != nil }
    }

    let config: VirtualDisplayConfig
    let displayID: CGDirectDisplayID
    private let display: CGVirtualDisplay

    /// Create the display and apply `config`. `onTerminate` fires (on
    /// the main queue, with this display's id) when WindowServer tears
    /// the display down — including after we release it ourselves.
    init(
        config: VirtualDisplayConfig,
        onTerminate: @escaping @MainActor (CGDirectDisplayID) -> Void
    ) throws {
        guard Self.isSupported else { throw VirtualDisplayError.unsupported }

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue.main
        descriptor.name = Self.displayName
        descriptor.maxPixelsWide = UInt32(config.preset.width * config.scale)
        descriptor.maxPixelsHigh = UInt32(config.preset.height * config.scale)
        // Physical size at ~110 points per inch (a typical desktop
        // monitor) so macOS picks sensible UI scaling defaults.
        descriptor.sizeInMillimeters = CGSize(
            width: Double(config.preset.width) / 110 * 25.4,
            height: Double(config.preset.height) / 110 * 25.4
        )
        // Stable identity so macOS remembers the display arrangement
        // across launches.
        descriptor.vendorID = 0x4650  // "FP"
        descriptor.productID = 0x0001
        descriptor.serialNum = 0x0001
        let idBox = DisplayIDBox()
        descriptor.terminationHandler = { _, _ in
            MainActor.assumeIsolated { onTerminate(idBox.id) }
        }

        guard let display = CGVirtualDisplay(descriptor: descriptor) else {
            throw VirtualDisplayError.createFailed
        }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = config.hiDPI ? 1 : 0
        // Modes are given in points; with hiDPI set, WindowServer also
        // offers each at 2× backing pixels (bounded by maxPixels).
        settings.modes = [
            CGVirtualDisplayMode(
                width: UInt(config.preset.width),
                height: UInt(config.preset.height),
                refreshRate: config.refreshRate
            ),
        ]
        guard display.apply(settings) else { throw VirtualDisplayError.applyFailed }

        self.display = display
        self.displayID = display.displayID
        idBox.id = display.displayID
        self.config = config
        selectMode()
    }

    /// Current size in points and backing pixels, read back from
    /// CoreGraphics (nil if the display is gone).
    var currentMode: (points: CGSize, pixels: CGSize, refreshRate: Double)? {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
        return (
            CGSize(width: mode.width, height: mode.height),
            CGSize(width: mode.pixelWidth, height: mode.pixelHeight),
            mode.refreshRate
        )
    }

    /// WindowServer activates the 1× variant by default; switch to the
    /// mode matching the config (the 2× one for HiDPI). The mode list
    /// can lag creation slightly, so retry briefly.
    private func selectMode(attempt: Int = 0) {
        let wantW = config.preset.width
        let wantPixelW = wantW * config.scale
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode]) ?? []
        if let current = CGDisplayCopyDisplayMode(displayID),
           current.width == wantW, current.pixelWidth == wantPixelW {
            return
        }
        guard let mode = modes.first(where: {
            $0.width == wantW && $0.height == config.preset.height && $0.pixelWidth == wantPixelW
        }) else {
            guard attempt < 10 else {
                print("[VirtualDisplay] mode \(wantW)pt/\(wantPixelW)px never appeared")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.selectMode(attempt: attempt + 1)
            }
            return
        }
        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success else { return }
        CGConfigureDisplayWithDisplayMode(configRef, displayID, mode, nil)
        let result = CGCompleteDisplayConfiguration(configRef, .forSession)
        if result != .success {
            print("[VirtualDisplay] mode switch failed: \(result.rawValue)")
        }
    }
}

/// Lets the termination handler (built before the display exists)
/// report which display it belonged to.
@MainActor
private final class DisplayIDBox {
    var id: CGDirectDisplayID = kCGNullDirectDisplay
}
