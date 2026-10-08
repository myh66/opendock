import AppKit
import CoreGraphics
import CryptoKit
import ScreenCaptureKit

struct WindowCaptureRequest {
    let key: String
    let processIdentifier: pid_t
    let title: String
    let frame: CGRect?
}

/// Saves only individual approved application-window snapshots. No display or
/// desktop filter is used, and capture never requests permission implicitly.
@MainActor
final class WindowPreviewCache {
    static let shared = WindowPreviewCache()
    struct Entry: Codable { let file: String; let updatedAt: Date }
    private(set) var entries: [String: Entry] = [:]
    private var images: [String: NSImage] = [:]
    private var enabled = false
    let directory: URL
    private var manifestURL: URL { directory.appendingPathComponent("index.json") }
    private let refreshInterval: TimeInterval = 12

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("OpenDock/window-previews", isDirectory: true)
        if let data = try? Data(contentsOf: manifestURL), let saved = try? JSONDecoder().decode([String: Entry].self, from: data) { entries = saved }
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if !enabled { clear() }
    }

    func image(for key: String) -> NSImage? {
        guard enabled else { return nil }
        if let image = images[key] { return image }
        guard let entry = entries[key], Self.validFilename(entry.file), let image = NSImage(contentsOf: directory.appendingPathComponent(entry.file)) else { return nil }
        images[key] = image; return image
    }

    @discardableResult
    func store(_ image: NSImage, for key: String, at date: Date = Date()) -> Bool {
        guard enabled, let representation = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: representation),
              let png = bitmap.representation(using: .png, properties: [:]) else { return false }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let filename = Self.filename(for: key)
            let url = directory.appendingPathComponent(filename)
            try png.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            entries[key] = Entry(file: filename, updatedAt: date); images[key] = image
            persistIndex(); return true
        } catch { return false }
    }

    func prune(keeping keys: Set<String>) {
        for key in Array(entries.keys) where !keys.contains(key) {
            if let entry = entries.removeValue(forKey: key), Self.validFilename(entry.file) { try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.file)) }
            images[key] = nil
        }
        if !entries.isEmpty { persistIndex() }
        else { try? FileManager.default.removeItem(at: manifestURL) }
    }

    func clear() {
        entries.removeAll(); images.removeAll()
        // Restrict removal to files this service owns, including orphaned PNGs
        // after a failed index write; never traverse other application data.
        if let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for url in urls where url.lastPathComponent == "index.json" || Self.validFilename(url.lastPathComponent) { try? FileManager.default.removeItem(at: url) }
        }
    }

    func capture(_ requests: [WindowCaptureRequest]) async {
        guard enabled, CGPreflightScreenCaptureAccess(), !Task.isCancelled else { return }
        let pending = requests.filter { request in
            guard let entry = entries[request.key] else { return true }
            return Date().timeIntervalSince(entry.updatedAt) >= refreshInterval
        }
        guard !pending.isEmpty else { return }
        if #available(macOS 14.0, *) {
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return }
            for request in pending {
                guard enabled, CGPreflightScreenCaptureAccess(), !Task.isCancelled else { return }
                let candidates = content.windows.filter { $0.owningApplication?.processID == request.processIdentifier && $0.windowLayer == 0 && $0.isOnScreen }
                guard let window = Self.match(request, candidates: candidates) else { continue }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let config = SCStreamConfiguration()
                let ratio = max(0.25, min(4, window.frame.width / max(window.frame.height, 1)))
                config.width = 360; config.height = max(90, min(300, Int(360 / ratio)))
                config.showsCursor = false; config.capturesAudio = false; config.ignoreShadowsSingleWindow = true
                guard let cgImage = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config), enabled, !Task.isCancelled else { continue }
                _ = store(NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)), for: request.key)
            }
        } else {
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            for request in pending {
                guard enabled, CGPreflightScreenCaptureAccess(), !Task.isCancelled else { return }
                let candidates = windows.filter { ($0[kCGWindowOwnerPID as String] as? Int) == Int(request.processIdentifier) && ($0[kCGWindowLayer as String] as? Int) == 0 }
                let byFrame = candidates.filter { candidate in
                    guard let frame = request.frame, let dictionary = candidate[kCGWindowBounds as String] as? [String: Any],
                          let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return false }
                    return abs(bounds.minX - frame.minX) < 3 && abs(bounds.minY - frame.minY) < 3 && abs(bounds.width - frame.width) < 3 && abs(bounds.height - frame.height) < 3
                }
                let byTitle = candidates.filter { ($0[kCGWindowName as String] as? String) == request.title }
                let candidate = byFrame.count == 1 ? byFrame[0] : byTitle.count == 1 ? byTitle[0] : (candidates.count == 1 ? candidates[0] : nil)
                guard let number = candidate?[kCGWindowNumber as String] as? UInt32,
                      let image = CGWindowListCreateImage(.null, .optionIncludingWindow, number, [.boundsIgnoreFraming, .bestResolution]) else { continue }
                let original = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                let size = NSSize(width: min(360, image.width), height: max(1, min(300, Int(Double(image.height) * min(1, 360 / Double(max(image.width, 1)))))))
                let thumbnail = NSImage(size: size, flipped: false) { rect in original.draw(in: rect); return true }
                _ = store(thumbnail, for: request.key)
            }
        }
    }

    @available(macOS 14.0, *)
    private static func match(_ request: WindowCaptureRequest, candidates: [SCWindow]) -> SCWindow? {
        if let frame = request.frame {
            let matching = candidates.filter { abs($0.frame.minX - frame.minX) < 3 && abs($0.frame.minY - frame.minY) < 3 && abs($0.frame.width - frame.width) < 3 && abs($0.frame.height - frame.height) < 3 }
            if matching.count == 1 { return matching[0] }
            if let titleMatch = matching.first(where: { $0.title == request.title }) { return titleMatch }
        }
        let titleMatches = candidates.filter { $0.title == request.title }
        return titleMatches.count == 1 ? titleMatches[0] : (candidates.count == 1 ? candidates[0] : nil)
    }

    private func persistIndex() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: manifestURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
    }

    nonisolated static func filename(for key: String) -> String { SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".png" }
    nonisolated static func validFilename(_ name: String) -> Bool { name.range(of: "^[a-f0-9]{64}\\.png$", options: .regularExpression) != nil }
}
