import AppKit
import QuickLookThumbnailing
import Quartz

@MainActor
final class FilePreviewService: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = FilePreviewService()
    private let cache = NSCache<NSString, NSImage>()
    private var requests: [String: Task<Data?, Never>] = [:]
    private var previewURLs: [URL] = []

    override init() {
        super.init()
        cache.countLimit = 256
        cache.totalCostLimit = 32 * 1024 * 1024
    }

    func thumbnail(for url: URL, size: CGSize = CGSize(width: 160, height: 120)) async -> NSImage? {
        guard url.isFileURL, size.width > 0, size.height > 0 else { return nil }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey])
        guard values?.isDirectory != true else { return nil }
        let key = Self.cacheKey(url: url, size: size, modificationDate: values?.contentModificationDate, fileSize: values?.fileSize)
        if let image = cache.object(forKey: key as NSString) { return image }
        if let existing = requests[key] { return await existing.value.flatMap { NSImage(data: $0) } }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let operation = Task<Data?, Never> {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
            let data: Data? = await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { continuation in
                    QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                        let data = representation.flatMap { NSBitmapImageRep(cgImage: $0.cgImage).representation(using: .png, properties: [:]) }
                        continuation.resume(returning: data)
                    }
                }
            }, onCancel: { QLThumbnailGenerator.shared.cancel(request) })
            guard !Task.isCancelled else { return nil }
            return data
        }
        requests[key] = operation
        let image = await operation.value.flatMap { NSImage(data: $0) }
        requests[key] = nil
        if let image { cache.setObject(image, forKey: key as NSString, cost: Int(size.width * size.height * scale * scale * 4)) }
        return Task.isCancelled ? nil : image
    }

    func invalidate() {
        for request in requests.values { request.cancel() }
        requests.removeAll(); cache.removeAllObjects()
    }

    func showQuickLook(_ urls: [URL]) {
        previewURLs = urls.filter(\.isFileURL)
        guard !previewURLs.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self; panel.currentPreviewItemIndex = 0
        panel.reloadData(); panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard previewURLs.indices.contains(index) else { return nil }
        return previewURLs[index] as NSURL
    }

    static func cacheKey(url: URL, size: CGSize, modificationDate: Date?, fileSize: Int?) -> String {
        "\(url.standardizedFileURL.path)|\(size.width)x\(size.height)|\(modificationDate?.timeIntervalSince1970 ?? 0)|\(fileSize ?? 0)"
    }
}
