import Foundation
import CryptoKit
import OSLog

private let repoLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "PrimaeNative",
    category: "LetterRepository"
)

/// Active font weight for stroke loading. Picks the subtree under
/// `Letters/<weight>/` to read polylines from. Letters whose Light
/// strokes.json is missing fall back to Regular at load time so a
/// partial Light bundle is shippable.
public enum FontWeight: String, CaseIterable {
    case regular
    case light

    /// On-disk subfolder name (`Letters/Regular/...`, `Letters/Light/...`).
    var folder: String {
        switch self {
        case .regular: return "Regular"
        case .light:   return "Light"
        }
    }

    /// Bundled font file inside `Resources/Fonts/`.
    var fontFile: String {
        switch self {
        case .regular: return "Primae-Regular.otf"
        case .light:   return "Primae-Light.otf"
        }
    }
}

private let fontWeightPreferenceKey = "de.flamingistan.primae.fontWeight"

/// Current user-preferred weight. Defaults to `.regular` (the
/// production-ready bake). `.light` is partial — letters whose Light
/// strokes.json is missing fall back at load time.
func currentFontWeight() -> FontWeight {
    let raw = UserDefaults.standard.string(forKey: fontWeightPreferenceKey) ?? "regular"
    return FontWeight(rawValue: raw) ?? .regular
}

protocol LetterResourceProviding {
    var bundle: Bundle { get }
    var searchBundles: [Bundle] { get }
    func allResourceURLs() -> [URL]
    func resourceURL(for relativePath: String) -> URL?
}

struct BundleLetterResourceProvider: LetterResourceProviding {
    let bundle: Bundle

    init(bundle: Bundle = BundleLetterResourceProvider.safeModuleBundle()) {
        self.bundle = bundle
    }

    /// Returns `Bundle.module` if available, falling back to
    /// `Bundle.main`. Avoids the `fatalError` SPM's generated
    /// `Bundle.module` accessor throws in test hosts.
    private static func safeModuleBundle() -> Bundle {
        let bundleName = "PrimaeNative_PrimaeNative"
        let candidates: [Bundle?] = [
            Bundle(identifier: bundleName),
            Bundle.allBundles.first(where: { $0.bundlePath.hasSuffix(bundleName + ".bundle") }),
            Bundle.allFrameworks.first(where: { $0.bundlePath.hasSuffix(bundleName + ".bundle") })
        ]
        return candidates.compactMap { $0 }.first ?? .main
    }

    var searchBundles: [Bundle] {
        var bundles: [Bundle] = [bundle]
        if bundle != .main { bundles.append(.main) }
        return bundles
    }

    func allResourceURLs() -> [URL] {
        let fm = FileManager.default
        return searchBundles.flatMap { b -> [URL] in
            guard let root = b.resourceURL else { return [] }
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            return enumerator.compactMap { $0 as? URL }.filter {
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
        }
    }

    func resourceURL(for relativePath: String) -> URL? {
        // Resources land in one of three layouts depending on how the
        // package is consumed: SPM `.copy("Resources")`, SPM
        // `.process(_:)` (flattened), or Xcode app-target copy. The
        // enumerator suffix match at the end guarantees the right
        // variant file even when the bundling layout shifts.
        let pathCandidates = [relativePath, "Resources/\(relativePath)"]
        for b in searchBundles {
            guard let root = b.resourceURL else { continue }
            for candidate in pathCandidates {
                let url = root.appendingPathComponent(candidate)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        let ns        = relativePath as NSString
        let file      = ns.lastPathComponent
        let directory = ns.deletingLastPathComponent
        let subdirCandidates: [String?] = directory.isEmpty
            ? [nil, "Resources"]
            : [nil, directory, "Resources/\(directory)"]
        for b in searchBundles {
            for subdir in subdirCandidates {
                if let subdir {
                    if let url = b.url(forResource: file, withExtension: nil, subdirectory: subdir) { return url }
                } else {
                    if let url = b.url(forResource: file, withExtension: nil) { return url }
                }
            }
        }
        // Last-resort enumerator pass — slow but exhaustive.
        let suffix = "/" + relativePath
        for url in allResourceURLs() {
            if url.path.hasSuffix(suffix) { return url }
        }
        return nil
    }
}

final class LetterRepository {
    struct ValidationIssue: Equatable {
        let letter: String
        let message: String
    }

    private let resources: LetterResourceProviding
    private let cache: LetterCacheStoring
    private let userDefaults: UserDefaults

    init(resources: LetterResourceProviding = BundleLetterResourceProvider(),
         cache: LetterCacheStoring = JSONLetterCache(),
         userDefaults: UserDefaults = .standard) {
        self.resources    = resources
        self.cache        = cache
        self.userDefaults = userDefaults
    }

    /// Loads letters from bundle with cache fallback. Never empty —
    /// falls back to a hardcoded sample letter.
    func loadLetters() -> [LetterAsset] {
        switch loadWithErrors() {
        case .success(let letters):
            return letters
        case .failure(let error):
            logError(error)
            return [fallbackSampleLetter()]
        }
    }

    /// Typed-error variant for callers that want to surface failures.
    func loadWithErrors() -> Result<[LetterAsset], LetterRepositoryError> {
        Self.verifyBakeMetadataOnce(resources: resources)
        let stroked = loadBundledStrokeLettersWithValidation()
        if !stroked.letters.isEmpty {
            logValidationIssues(stroked.letters, issues: stroked.issues)
            persistToCache(stroked.letters)
            return .success(stroked.letters)
        }

        // Bundle failed — try cache as fallback.
        if let cached = loadFromCache() {
            repoLogger.info("Using cached letters (bundle load failed)")
            return .success(cached)
        }

        let allIssues = stroked.issues.map { "\($0.letter): \($0.message)" }
        if !allIssues.isEmpty {
            return .failure(.partialLoad(loaded: 0, issues: allIssues))
        }
        return .failure(.noAssetsFound)
    }

    /// Warm-launch optimisation: return the cached letters when they
    /// were written by the currently-running build. App-Store builds
    /// bump `CFBundleVersion`, which auto-invalidates the cache.
    /// Falls back to the bundle path on miss / stale / missing sentinel.
    func loadLettersFast() -> [LetterAsset] {
        if let bundleVersion = currentBundleVersion,
           let cachedVersion = userDefaults.string(forKey: Self.cacheBundleVersionKey),
           cachedVersion == bundleVersion,
           let cached = loadFromCache(),
           !cached.isEmpty {
            return cached
        }
        return loadLetters()
    }

    /// Bundle-version sentinel paired with the cache file. The
    /// trailing `.vN` is a manual bust knob — bump when the stroke
    /// generator's output convention changes (dev builds reuse
    /// `CFBundleVersion` between commits, so a JSON-shape refactor
    /// would otherwise keep serving the old cached strokes).
    private static let cacheBundleVersionKey = "PrimaeNative.LetterCache.bundleVersion.v20"

    /// Build identifier — `CFBundleShortVersionString-CFBundleVersion`.
    /// Returns nil in unit-test hosts so the fast path defers to the
    /// slow path rather than serving stale data.
    private var currentBundleVersion: String? {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let parts = [short, build].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "-")
    }

    // MARK: - Private

    private func persistToCache(_ letters: [LetterAsset]) {
        do {
            try cache.save(letters)
        } catch {
            // Skip the version stamp on write failure — never claim a
            // valid cache for a build whose file is missing/corrupt.
            return
        }
        if let version = currentBundleVersion {
            userDefaults.set(version, forKey: Self.cacheBundleVersionKey)
        }
    }

    private func loadFromCache() -> [LetterAsset]? {
        guard let letters = try? cache.load(), !letters.isEmpty else { return nil }
        // Reject caches with any empty-stroke letter — an empty array
        // would skip observe + direct and drop the child straight
        // into Nachspuren. Falling back to the bundle re-reads
        // strokes.json fresh and self-repairs on the next persist.
        guard letters.allSatisfy({ !$0.strokes.strokes.isEmpty }) else { return nil }
        return letters
    }

    private func logError(_ error: LetterRepositoryError) {
        switch error {
        case .noAssetsFound:
            repoLogger.error("No assets found in bundle or cache — using fallback letter")
        case .partialLoad(_, let issues):
            repoLogger.warning("Partial load. Issues: \(issues.joined(separator: "; "))")
        case .cacheCorrupted(let msg):
            repoLogger.error("Cache corrupted: \(msg)")
        case .cacheReadFailed(let path):
            repoLogger.warning("Cache not found at \(path)")
        }
    }
}

private extension LetterRepository {
    typealias ValidationResult = (letters: [LetterAsset], issues: [ValidationIssue])

    func loadBundledStrokeLettersWithValidation() -> ValidationResult {
        let activeWeight = currentFontWeight()
        let fallbackWeight: FontWeight = .regular
        let otherWeightFolders = Set(FontWeight.allCases
            .filter { $0 != activeWeight }
            .map { $0.folder })
        let allJSONURLs = resources.allResourceURLs().filter {
            $0.pathExtension.lowercased() == "json"
        }
        // Accept URLs that are either under the active weight's subtree
        // OR have no weight subtree at all (test fixtures, legacy
        // layouts). Reject URLs in any other weight's subtree.
        func isInOtherWeight(_ url: URL) -> Bool {
            url.pathComponents.contains(where: otherWeightFolders.contains)
        }
        var urls = allJSONURLs.filter { !isInOtherWeight($0) }

        // Fallback: for any letter folder under the FALLBACK subtree
        // (Regular) that isn't yet covered by the active weight's
        // subtree, splice in the Regular URL. Lets a partial Light
        // bundle ship — letters whose Light spec isn't tuned fall back
        // silently to the Regular polyline.
        if activeWeight != fallbackWeight {
            let coveredFolderNames = Set(urls.map {
                $0.deletingLastPathComponent().lastPathComponent
            })
            let fallbackURLs = allJSONURLs.filter { url in
                url.pathComponents.contains(fallbackWeight.folder)
                && !coveredFolderNames.contains(
                    url.deletingLastPathComponent().lastPathComponent)
            }
            let fallbackLetters = fallbackURLs.map {
                $0.deletingLastPathComponent().lastPathComponent
            }
            urls.append(contentsOf: fallbackURLs)
            if !fallbackLetters.isEmpty {
                repoLogger.info("FontWeight=\(activeWeight.rawValue, privacy: .public) bundle is partial; \(fallbackLetters.count, privacy: .public) letters fell back to \(fallbackWeight.rawValue, privacy: .public): \(fallbackLetters.joined(separator: ","), privacy: .public)")
            }
        }
        let decoder = JSONDecoder()
        var issues: [ValidationIssue] = []

        let letters = urls.compactMap { url -> LetterAsset? in
            let filename     = url.lastPathComponent
            let isStrokesFile = filename.hasSuffix("_strokes.json") || filename == "strokes.json"
            guard isStrokesFile else { return nil }
            guard let data   = try? Data(contentsOf: url),
                  let strokes = try? decoder.decode(LetterStrokes.self, from: data) else {
                issues.append(.init(letter: url.lastPathComponent, message: "Invalid stroke JSON"))
                return nil
            }

            // Folder name (or `<x>_strokes.json` stem) is the letter.
            // Lowercase folders carry a `_l` suffix to avoid case
            // collisions on case-insensitive APFS/HFS+ (`A` and `a`
            // fold to the same node and would overwrite each other
            // at install time).
            let folderName: String
            if filename.hasSuffix("_strokes.json") {
                folderName = url.deletingPathExtension().lastPathComponent
                    .replacingOccurrences(of: "_strokes", with: "")
            } else {
                folderName = url.deletingLastPathComponent().lastPathComponent
            }
            let isLowercaseFolder = folderName.hasSuffix("_l") && folderName.count > 1
            let base: String = isLowercaseFolder
                ? String(folderName.dropLast(2))   // strip "_l"
                : folderName
            guard !base.isEmpty, base.count <= 2 else { return nil }

            let imageBase = isLowercaseFolder ? "\(base)_l" : base

            let allAudio = findAudioAssets(for: base)
            if allAudio.isEmpty {
                // A valid strokes.json is enough to trace; letters
                // without recordings stay silent on proximity events.
                issues.append(.init(letter: base, message: "No audio files found in bundle for letter"))
            }
            // Phoneme recordings: `<base>_phoneme<n>.<ext>`. The
            // parent's "Lautwert wiedergeben" toggle picks which
            // population plays.
            let (audio, phonemeAudio) = partitionPhonemeAudio(allAudio)

            // displayName preserves picker case (`A` vs `a`);
            // baseLetter keys progress/audio (uppercase or `ß`);
            // letterCase comes from the folder suffix.
            let displayName = isLowercaseFolder ? base.lowercased() : base
            let baseLetter = base == "ß" ? "ß" : base.uppercased()
            let letterCase: LetterAsset.LetterCase = isLowercaseFolder ? .lower : .upper
            // `variants` are alternate stroke *orders* within the same
            // script (e.g. F's two horizontal-bar sequences). Scripts
            // themselves flow through `SchriftArt.bundleVariantID`.
            var variantIDs: [String] = []
            if bundleHasResource(at: "Letters/\(activeWeight.folder)/\(imageBase)/strokes_variant.json")
               || bundleHasResource(at: "Letters/\(fallbackWeight.folder)/\(imageBase)/strokes_variant.json") {
                variantIDs.append("variant")
            }
            let variants: [String]? = variantIDs.isEmpty ? nil : variantIDs
            return LetterAsset(id: imageBase, name: displayName,
                               baseLetter: baseLetter, letterCase: letterCase,
                               audioFiles: audio, strokes: strokes,
                               variants: variants,
                               phonemeAudioFiles: phonemeAudio)
        }.sorted { $0.name < $1.name }

        return (letters, issues)
    }

    /// Split into letter-name vs phoneme populations.
    /// Phoneme files: `<base>_phoneme<n>.<ext>` (case-insensitive).
    /// Sorted output keeps playback deterministic.
    func partitionPhonemeAudio(_ files: [String]) -> (name: [String], phoneme: [String]) {
        var name: [String] = []
        var phoneme: [String] = []
        for f in files.sorted() {
            let leaf = (f as NSString).lastPathComponent.lowercased()
            if leaf.contains("_phoneme") {
                phoneme.append(f)
            } else {
                name.append(f)
            }
        }
        return (name, phoneme)
    }

    func findAudioAssets(for base: String) -> [String] {
        let supported    = Set(["mp3", "wav", "m4a", "aac", "flac", "ogg"])
        let allResources = resources.allResourceURLs()
        let bundleRoots: [String] = resources.searchBundles.compactMap {
            guard let p = $0.resourceURL?.path else { return nil }
            return p.hasSuffix("/") ? p : p + "/"
        }

        let audio = allResources.compactMap { url -> String? in
            let ext = url.pathExtension.lowercased()
            guard supported.contains(ext) else { return nil }

            let normalizedPath = url.path.replacingOccurrences(of: "\\", with: "/")
            let marker = "/\(base)/"
            if normalizedPath.range(of: marker, options: [.caseInsensitive]) != nil {
                for root in bundleRoots where normalizedPath.hasPrefix(root) {
                    return String(normalizedPath.dropFirst(root.count))
                }
                if let markerRange = normalizedPath.range(of: marker, options: [.caseInsensitive]) {
                    return String(normalizedPath[markerRange.lowerBound...].dropFirst())
                }
            }

            let file = url.lastPathComponent
            if file.lowercased().hasPrefix(base.lowercased()) { return file }
            return nil
        }

        // Filter stale references before downstream matching so e.g.
        // `hmmm.wav` can never satisfy H via the hasPrefix fallback.
        let unique = Array(Set(audio)).sorted().filter { !isLikelyStaleAudioReference($0) }
        let preferred = preferredAudioFiles(for: base, available: unique)
        if !preferred.isEmpty { return preferred }

        if ["I", "O"].contains(base.uppercased()), let first = unique.first { return [first] }
        return unique
    }

    func preferredAudioFiles(for base: String, available: [String]) -> [String] {
        let marker = "/\(base.uppercased())/"
        let subfolderPaths = available.filter {
            $0.range(of: marker, options: .caseInsensitive) != nil
        }.sorted()
        if !subfolderPaths.isEmpty { return subfolderPaths }

        return available.filter {
            let file = ($0 as NSString).lastPathComponent
            return file.lowercased().hasPrefix(base.lowercased())
        }.sorted()
    }

    /// Files matched by the hasPrefix fallback that aren't letter
    /// recordings. Without this list `tap.wav` becomes the "letter
    /// audio" for T and plays on every T proximity event.
    private static let nonLetterAudioBasenames: Set<String> = [
        "tap.wav", "tap_wrong.wav", "tick_stroke.wav", "hmmm.wav"
    ]

    func isLikelyStaleAudioReference(_ path: String) -> Bool {
        let lower = path.lowercased()
        let leaf = ((lower as NSString).lastPathComponent)
        if Self.nonLetterAudioBasenames.contains(leaf)  { return true }
        if lower.contains("elevenlabs_")                { return true }
        if lower.contains("friendly and approachable")  { return true }
        if lower.contains(" (1).")                      { return true }
        return false
    }

    func bundleHasResource(at relativePath: String) -> Bool {
        resources.resourceURL(for: relativePath) != nil
    }

    /// Hardcoded stroke definition for the no-assets fallback. Only the
    /// "A" path is reachable; bundle scan covers every other letter.
    func fallbackSampleLetter() -> LetterAsset {
        let strokes = LetterStrokes(letter: "A", checkpointRadius: 0.04, strokes: [
            .init(id: 1, checkpoints: [
                .init(x: 0.58, y: 0.04), .init(x: 0.52, y: 0.13),
                .init(x: 0.42, y: 0.30), .init(x: 0.34, y: 0.44),
                .init(x: 0.25, y: 0.60), .init(x: 0.15, y: 0.78), .init(x: 0.03, y: 0.99)]),
            .init(id: 2, checkpoints: [
                .init(x: 0.58, y: 0.04), .init(x: 0.66, y: 0.17),
                .init(x: 0.73, y: 0.35), .init(x: 0.78, y: 0.48),
                .init(x: 0.82, y: 0.60), .init(x: 0.90, y: 0.79), .init(x: 0.97, y: 0.98)]),
            .init(id: 3, checkpoints: [
                .init(x: 0.26, y: 0.60), .init(x: 0.553, y: 0.60), .init(x: 0.82, y: 0.60)])
        ])
        return LetterAsset(id: "A", name: "A",
                           audioFiles: ["A1.mp3"], strokes: strokes)
    }

    func logValidationIssues(_ letters: [LetterAsset], issues: [ValidationIssue]) {
        // Stroke JSONs ship for every letter; audio recordings exist
        // only for the recorded subset. Summary at .info; per-letter
        // detail at .debug.
        guard !issues.isEmpty else { return }
        let missingAudio = issues.filter { $0.message.contains("No audio files") }.count
        let otherCount   = issues.count - missingAudio
        repoLogger.info("Asset validation: \(letters.count) letters loaded, \(missingAudio)/\(letters.count) without audio recordings, \(otherCount) other issue(s). Per-letter details at debug level.")
        for issue in issues {
            repoLogger.debug("Asset validation [\(issue.letter)]: \(issue.message)")
        }
    }
}

// MARK: - Bake metadata verification

extension LetterRepository {
    private struct BakeMeta: Codable {
        let fontPath: String
        let fontSha256: String
    }

    nonisolated(unsafe) private static var didVerifyBakeMetadata = false

    /// Verifies that each bundled Primae font matches the SHA-256
    /// recorded in `Letters/<Weight>/_meta.json` at bake time. A
    /// mismatch means the font was updated without re-running
    /// `generate_strokes_auto.py`, so that weight's strokes.json
    /// polylines no longer match the rendered glyph. Runs once per
    /// process; never fatal — logs each weight's status independently.
    static func verifyBakeMetadataOnce(resources: LetterResourceProviding) {
        guard !didVerifyBakeMetadata else { return }
        didVerifyBakeMetadata = true

        for weight in [FontWeight.regular, .light] {
            verifyWeight(weight, resources: resources)
        }
    }

    private static func verifyWeight(_ weight: FontWeight,
                                     resources: LetterResourceProviding) {
        guard let metaURL = resources.resourceURL(
                for: "Letters/\(weight.folder)/_meta.json"),
              let metaData = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(BakeMeta.self, from: metaData)
        else {
            repoLogger.debug("\(weight.rawValue, privacy: .public) bake metadata absent — skipping font-hash check.")
            return
        }
        let fontFile = (meta.fontPath as NSString).lastPathComponent
        guard let fontURL = resources.resourceURL(for: "Fonts/\(fontFile)"),
              let fontData = try? Data(contentsOf: fontURL)
        else {
            repoLogger.debug("Bundled font \(fontFile, privacy: .public) not found — skipping hash check for \(weight.rawValue, privacy: .public).")
            return
        }
        let digest = SHA256.hash(data: fontData)
            .map { String(format: "%02x", $0) }.joined()
        if digest != meta.fontSha256 {
            repoLogger.warning("Bundled font \(fontFile, privacy: .public) SHA-256 mismatch: bundle=\(digest, privacy: .public) meta=\(meta.fontSha256, privacy: .public). Re-run scripts/generate_strokes_auto.py --weight \(weight.rawValue, privacy: .public).")
        } else {
            repoLogger.debug("\(weight.rawValue, privacy: .public) bake font hash verified.")
        }
    }
}

// MARK: - Variant stroke loading

extension LetterRepository {
    /// Load alternate stroke data from
    /// `Letters/<Weight>/{letter}/strokes_{variantID}.json`. Probes the
    /// active weight first, then Regular as fallback. Probes both the
    /// suffixed (`_l`) and bare folder names for lowercase letters.
    func loadVariantStrokes(for letter: String, variantID: String) -> LetterStrokes? {
        let folderCandidates: [String]
        if letter == letter.uppercased() && letter != letter.lowercased() {
            folderCandidates = [letter]                    // uppercase
        } else if letter == letter.lowercased() && letter != letter.uppercased() {
            folderCandidates = ["\(letter)_l", letter]     // lowercase
        } else {
            folderCandidates = [letter]                    // ß / specials
        }
        let active = currentFontWeight()
        let weightCandidates: [FontWeight] = active == .regular
            ? [.regular] : [active, .regular]
        let paths = weightCandidates.flatMap { w in
            folderCandidates.flatMap { folder in
                [
                    "Letters/\(w.folder)/\(folder)/strokes_\(variantID).json",
                    "\(folder)/strokes_\(variantID).json"
                ]
            }
        }
        let decoder = JSONDecoder()
        for path in paths {
            guard let url = resources.resourceURL(for: path),
                  let data = try? Data(contentsOf: url),
                  let strokes = try? decoder.decode(LetterStrokes.self, from: data)
            else { continue }
            return strokes
        }
        return nil
    }
}
