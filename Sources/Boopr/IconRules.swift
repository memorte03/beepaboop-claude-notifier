import AppKit
import Combine

/// One user-defined project icon: a regex matched against the directory the
/// Claude session runs in (`cwd` from the hook payload) plus an image.
struct ProjectIconRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var pattern: String = ""
    /// Filename inside `IconRuleStore.iconsDir` (imported copy, not the original).
    var iconFile: String?
}

/// Persists icon rules as JSON in the config dir (next to the auth token) and
/// resolves cwd → image with compiled-regex and image caches. First matching
/// rule wins; the list order in Settings is the priority order.
@MainActor
final class IconRuleStore: ObservableObject {
    @Published var rules: [ProjectIconRule] {
        didSet {
            save()
            rebuildRegexCache()
            pruneOrphanedImages()
        }
    }

    private var regexCache: [UUID: NSRegularExpression] = [:]
    private var imageCache: [String: NSImage] = [:]

    static var iconsDir: URL { AuthToken.configDir.appendingPathComponent("icons") }
    private static var rulesFile: URL { AuthToken.configDir.appendingPathComponent("icon-rules.json") }

    init() {
        rules = (try? JSONDecoder().decode(
            [ProjectIconRule].self, from: Data(contentsOf: Self.rulesFile))) ?? []
        rebuildRegexCache()
    }

    // MARK: matching

    /// The image for the first rule whose regex matches anywhere in `cwd`.
    func icon(forCwd cwd: String?) -> NSImage? {
        guard let cwd, !cwd.isEmpty else { return nil }
        for rule in rules {
            guard let file = rule.iconFile,
                  let regex = regexCache[rule.id],
                  regex.firstMatch(in: cwd, range: NSRange(cwd.startIndex..., in: cwd)) != nil
            else { continue }
            return image(named: file)
        }
        return nil
    }

    func isValidPattern(_ pattern: String) -> Bool {
        !pattern.isEmpty && (try? NSRegularExpression(pattern: pattern)) != nil
    }

    // MARK: image handling

    /// Copies a user-chosen image into the icons dir and returns the stored
    /// filename. Throws if the file can't be loaded as an image (bad SVG etc.).
    func importImage(from url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        guard NSImage(data: data) != nil else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey: "\(url.lastPathComponent) couldn't be read as an image."
            ])
        }
        try FileManager.default.createDirectory(at: Self.iconsDir, withIntermediateDirectories: true)
        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension.lowercased()
        let name = UUID().uuidString + "." + ext
        try data.write(to: Self.iconsDir.appendingPathComponent(name))
        return name
    }

    func image(named file: String) -> NSImage? {
        if let cached = imageCache[file] { return cached }
        guard let img = NSImage(contentsOf: Self.iconsDir.appendingPathComponent(file)) else {
            return nil
        }
        imageCache[file] = img
        return img
    }

    // MARK: private

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(rules) else { return }
        try? FileManager.default.createDirectory(at: AuthToken.configDir, withIntermediateDirectories: true)
        try? data.write(to: Self.rulesFile, options: .atomic)
    }

    private func rebuildRegexCache() {
        regexCache = Dictionary(uniqueKeysWithValues: rules.compactMap { rule in
            (try? NSRegularExpression(pattern: rule.pattern)).map { (rule.id, $0) }
        })
    }

    /// Deletes imported images no rule references anymore.
    private func pruneOrphanedImages() {
        let referenced = Set(rules.compactMap(\.iconFile))
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: Self.iconsDir.path) else { return }
        for file in files where !referenced.contains(file) {
            try? fm.removeItem(at: Self.iconsDir.appendingPathComponent(file))
            imageCache[file] = nil
        }
    }
}
