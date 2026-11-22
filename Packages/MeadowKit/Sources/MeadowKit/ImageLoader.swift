import AppKit

/// Loads and caches images referenced by documents. Calls `onLoad` on the main thread.
public final class ImageLoader {
    public var onLoad: (() -> Void)?
    private var cache: [URL: NSImage] = [:]
    private var loading = Set<URL>()
    private var failed = Set<URL>()
    public var allowsRemote = true

    public init() {}

    public func image(for url: URL) -> NSImage? {
        if let img = cache[url] { return img }
        if loading.contains(url) || failed.contains(url) { return nil }
        if !url.isFileURL && !allowsRemote { return nil }
        loading.insert(url)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let data = try? Data(contentsOf: url)
            let image = data.flatMap { NSImage(data: $0) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading.remove(url)
                if let image { self.cache[url] = image } else { self.failed.insert(url) }
                if image != nil { self.onLoad?() }
            }
        }
        return nil
    }

    public static func resolve(_ src: String, base: URL?) -> URL? {
        let trimmed = src.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let u = URL(string: trimmed), let scheme = u.scheme?.lowercased(),
           ["http", "https", "file"].contains(scheme) { return u }
        let path = trimmed.removingPercentEncoding ?? trimmed
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if path.hasPrefix("~") { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        return base?.appendingPathComponent(path).standardizedFileURL
    }
}
