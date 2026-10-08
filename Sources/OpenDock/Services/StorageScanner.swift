import AppKit
import Combine
import Foundation

enum StorageScanScope: String, CaseIterable, Identifiable {
    case home, applications, library
    var id: String { rawValue }
    var title: String { self == .home ? "用户文件夹" : self == .applications ? "应用程序" : "用户资源库" }
    var url: URL {
        switch self {
        case .home: return FileManager.default.homeDirectoryForCurrentUser
        case .applications: return URL(fileURLWithPath: "/Applications", isDirectory: true)
        case .library: return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        }
    }
}

struct StorageEntry: Identifiable, Sendable {
    var id: String { url.path }
    let name: String
    let url: URL
    let bytes: UInt64
    let logicalBytes: UInt64
    let isDirectory: Bool
    let children: [StorageEntry]
}

struct StorageScanResult: Sendable {
    let root: StorageEntry
    var bytes: UInt64 { root.bytes }
    var logicalBytes: UInt64 { root.logicalBytes }
    let fileCount: Int
    let isPartial: Bool
    let wasCancelled: Bool
    let errorMessages: [String]
    let completedAt: Date
}

/// Scans are owned by this shared service, so closing a widget popover does not
/// cancel them. No filesystem enumeration happens in init, and deletion is not
/// offered. Protected paths are skipped and reported as partial results.
@MainActor
final class StorageScanner: ObservableObject {
    static let shared = StorageScanner()
    @Published private(set) var result: StorageScanResult?
    @Published private(set) var scanning = false
    @Published private(set) var progress = "选择范围后开始扫描"
    @Published private(set) var errorMessage: String?
    private var worker: Task<StorageScanResult, Never>?
    private var completion: Task<Void, Never>?
    private var generation = UUID()

    func start(scope: StorageScanScope) { scan(url: scope.url) }

    func scan(url: URL) {
        guard url.isFileURL else { errorMessage = "请选择本机文件夹。"; return }
        worker?.cancel(); completion?.cancel()
        generation = UUID(); let token = generation
        scanning = true; errorMessage = nil; progress = "正在检查 \(url.lastPathComponent)…"
        let service = self
        let operation = Task.detached(priority: .utility) {
            Self.scanDirectory(at: url) { count, bytes in
                Task { @MainActor in
                    guard service.generation == token else { return }
                    service.progress = "已检查 \(count) 个文件 · \(ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file))"
                }
            }
        }
        worker = operation
        completion = Task { [weak self] in
            let value = await operation.value
            guard let self, self.generation == token else { return }
            self.result = value; self.scanning = false; self.worker = nil; self.completion = nil
            self.progress = value.wasCancelled ? "已取消 · 结果不完整" : value.isPartial ? "扫描完成 · 部分位置无法读取" : "扫描完成"
            self.errorMessage = value.errorMessages.isEmpty ? nil : "\(value.errorMessages.count) 处位置无法读取；结果为可访问文件的大小。"
        }
    }

    func cancel() {
        worker?.cancel()
        if scanning { progress = "正在取消…" }
    }

    func reveal(_ entry: StorageEntry) { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }

    /// This pure traversal entry point is testable with temporary fixtures. It
    /// counts allocated bytes separately from logical file lengths, deduplicates
    /// hard links, never follows symlinks, and preserves totals beyond UI depth.
    nonisolated static func scanDirectory(at requestedURL: URL, progress: @escaping @Sendable (Int, UInt64) -> Void = { _, _ in }) -> StorageScanResult {
        let original = requestedURL.standardizedFileURL
        let root = original.resolvingSymlinksInPath()
        let state = ScanState(root: root)
        do {
            let values = try original.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                state.errors.append("扫描范围不是可读取的文件夹。")
                return state.result(cancelled: false)
            }
        } catch { state.errors.append(error.localizedDescription); return state.result(cancelled: false) }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey, .fileResourceIdentifierKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { url, error in
            if state.errors.count < 25 { state.errors.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
            return true
        }) else { state.errors.append("无法遍历此文件夹。"); return state.result(cancelled: false) }
        var lastUpdate = Date.distantPast
        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled { return state.result(cancelled: true) }
            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                let isDirectory = values.isDirectory == true
                state.addHierarchy(for: url, isDirectory: isDirectory)
                guard !isDirectory, values.isRegularFile == true else { continue }
                state.fileCount += 1
                if let identifier = values.fileResourceIdentifier as? AnyHashable, !state.fileIDs.insert(identifier).inserted { continue }
                let logical = UInt64(max(0, values.fileSize ?? 0))
                let allocated = UInt64(max(0, values.totalFileAllocatedSize ?? values.fileSize ?? 0))
                state.addSize(for: url, allocated: allocated, logical: logical)
                if Date().timeIntervalSince(lastUpdate) > 0.5 {
                    progress(state.fileCount, state.nodes[root.path]?.bytes ?? 0); lastUpdate = Date()
                }
            } catch { if state.errors.count < 25 { state.errors.append("\(url.lastPathComponent)：\(error.localizedDescription)") }; enumerator.skipDescendants() }
        }
        progress(state.fileCount, state.nodes[root.path]?.bytes ?? 0)
        return state.result(cancelled: false)
    }

    deinit { worker?.cancel(); completion?.cancel() }
}

private final class StorageAccumulator {
    let url: URL
    let isDirectory: Bool
    var bytes: UInt64 = 0
    var logicalBytes: UInt64 = 0
    var children = Set<String>()
    init(url: URL, isDirectory: Bool) { self.url = url; self.isDirectory = isDirectory }
}

private final class ScanState {
    let root: URL
    let rootDepth: Int
    var nodes: [String: StorageAccumulator]
    var fileCount = 0
    var fileIDs = Set<AnyHashable>()
    var errors: [String] = []
    var detailLimitReached = false
    private let maximumNodes = 30_000
    private let displayDepth = 3

    init(root: URL) { self.root = root; rootDepth = root.pathComponents.count; nodes = [root.path: StorageAccumulator(url: root, isDirectory: true)] }

    func hierarchy(_ url: URL) -> [URL] {
        // FileManager may return /private/var children for a /var root. Normalize
        // both sides before computing depth so the display tree stays relative.
        let relative = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents.dropFirst(rootDepth)
        var current = root, result = [root]
        for component in relative.prefix(displayDepth) { current.appendPathComponent(component); result.append(current) }
        return result
    }

    func addHierarchy(for url: URL, isDirectory: Bool) {
        let paths = hierarchy(url)
        let normalizedPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        for index in 1..<paths.count {
            let current = paths[index]
            if nodes[current.path] == nil {
                guard nodes.count < maximumNodes else { detailLimitReached = true; return }
                nodes[current.path] = StorageAccumulator(url: current, isDirectory: current.path != normalizedPath || isDirectory)
                nodes[paths[index - 1].path]?.children.insert(current.path)
            }
        }
    }

    func addSize(for url: URL, allocated: UInt64, logical: UInt64) {
        for path in hierarchy(url) { nodes[path.path]?.bytes += allocated; nodes[path.path]?.logicalBytes += logical }
    }

    func result(cancelled: Bool) -> StorageScanResult {
        func entry(_ key: String) -> StorageEntry {
            let value = nodes[key]!
            let childEntries: [StorageEntry] = value.children.map { entry($0) }
            let children = childEntries.sorted { first, second in
                if first.bytes != second.bytes { return first.bytes > second.bytes }
                return first.name.localizedStandardCompare(second.name) == .orderedAscending
            }
            return StorageEntry(name: value.url.lastPathComponent, url: value.url, bytes: value.bytes, logicalBytes: value.logicalBytes, isDirectory: value.isDirectory, children: children)
        }
        return StorageScanResult(root: entry(root.path), fileCount: fileCount, isPartial: cancelled || !errors.isEmpty || detailLimitReached,
                                 wasCancelled: cancelled, errorMessages: errors, completedAt: Date())
    }
}
