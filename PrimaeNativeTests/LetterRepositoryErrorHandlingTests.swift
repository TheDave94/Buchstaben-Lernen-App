import Testing
import Foundation
@testable import PrimaeNative

private final class EmptyResourceProvider: LetterResourceProviding {
    var bundle: Bundle = .main
    var searchBundles: [Bundle] { [bundle] }
    func allResourceURLs() -> [URL] { [] }
    func resourceURL(for relativePath: String) -> URL? { nil }
}

private final class InMemoryCache: LetterCacheStoring {
    private(set) var savedLetters: [LetterAsset]?
    private(set) var saveCallCount = 0
    private(set) var loadCallCount = 0
    var storedLetters: [LetterAsset]?
    var shouldThrowOnLoad = false

    init(storedLetters: [LetterAsset]? = nil) { self.storedLetters = storedLetters }

    func save(_ letters: [LetterAsset]) throws(LetterRepositoryError) {
        savedLetters = letters; storedLetters = letters; saveCallCount += 1
    }

    func load() throws(LetterRepositoryError) -> [LetterAsset] {
        loadCallCount += 1
        if shouldThrowOnLoad { throw LetterRepositoryError.cacheReadFailed(path: "/tmp/test") }
        guard let letters = storedLetters else {
            throw LetterRepositoryError.cacheReadFailed(path: "/tmp/test")
        }
        return letters
    }

    func clear() { storedLetters = nil; savedLetters = nil }
}

private func makeSampleLetter(_ id: String = "A") -> LetterAsset {
    LetterAsset(id: id, name: id.uppercased(), audioFiles: ["\(id).mp3"],
        strokes: LetterStrokes(letter: id.uppercased(), checkpointRadius: 0.05,
            strokes: [StrokeDefinition(id: 1, checkpoints: [Checkpoint(x: 0.5, y: 0.5)])]))
}

// MARK: - JSONLetterCache tests

@Suite @MainActor struct JSONLetterCacheTests {

    let tempURL: URL
    let cache: JSONLetterCache

    init() {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LetterCacheTest-\(UUID().uuidString).json")
        cache = JSONLetterCache(fileURL: tempURL)
    }

    @Test func saveAndLoad_roundtrips() throws {
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let letters = [makeSampleLetter("A"), makeSampleLetter("B")]
        try cache.save(letters)
        let loaded = try cache.load()
        #expect(loaded.map(\.id) == ["A", "B"])
        #expect(loaded.map(\.name) == ["A", "B"])
        #expect(loaded[0].audioFiles == ["A.mp3"])
    }

    @Test func load_whenNoFile_throwsCacheReadFailed() {
        defer { try? FileManager.default.removeItem(at: tempURL) }
        #expect {
            try cache.load()
        } throws: { error in
            if case LetterRepositoryError.cacheReadFailed = error { return true }
            return false
        }
    }

    @Test func clear_removesFile() throws {
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try cache.save([makeSampleLetter("C")])
        cache.clear()
        #expect(throws: (any Error).self) { try cache.load() }
    }

    @Test func save_isAtomic_doesNotCorruptOnRepeat() throws {
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try cache.save([makeSampleLetter("X")])
        try cache.save([makeSampleLetter("Y"), makeSampleLetter("Z")])
        let loaded = try cache.load()
        #expect(loaded.map(\.id) == ["Y", "Z"])
    }

    @Test func saveAndLoad_preservesStrokeGeometry() throws {
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let strokes = LetterStrokes(letter: "M", checkpointRadius: 0.07,
            strokes: [StrokeDefinition(id: 1, checkpoints: [Checkpoint(x: 0.1, y: 0.9), Checkpoint(x: 0.5, y: 0.1)])])
        let letter = LetterAsset(id: "M", name: "M", audioFiles: ["M.mp3"], strokes: strokes)
        try cache.save([letter])
        let loaded = try cache.load()
        #expect(abs(loaded[0].strokes.checkpointRadius - 0.07) < 1e-9)
        #expect(abs(loaded[0].strokes.strokes[0].checkpoints[1].x - 0.5) < 1e-9)
    }
}

// MARK: - LetterRepository error handling tests

@Suite struct LetterRepositoryErrorHandlingTests {

    @Test func emptyBundle_usesCacheFallback() {
        let cache = InMemoryCache(storedLetters: [makeSampleLetter("A"), makeSampleLetter("B")])
        let repo = LetterRepository(resources: EmptyResourceProvider(), cache: cache)
        #expect(repo.loadLetters().map(\.id).sorted() == ["A", "B"])
    }

    @Test func emptyBundle_withEmptyCache_returnsFallbackSample() {
        let repo = LetterRepository(resources: EmptyResourceProvider(), cache: InMemoryCache())
        let letters = repo.loadLetters()
        #expect(letters.count == 1)
        #expect(letters[0].id == "A")
    }

    @Test func loadWithErrors_emptyBundle_emptyCache_returnsNoAssetsFoundError() {
        let repo = LetterRepository(resources: EmptyResourceProvider(), cache: InMemoryCache())
        if case .failure(let error) = repo.loadWithErrors() {
            #expect(error == .noAssetsFound)
        } else {
            Issue.record("Expected failure, got success")
        }
    }

    @Test func loadWithErrors_emptyBundle_withCache_returnsSuccess() {
        let cache = InMemoryCache(storedLetters: [makeSampleLetter("F")])
        let repo = LetterRepository(resources: EmptyResourceProvider(), cache: cache)
        if case .success(let letters) = repo.loadWithErrors() {
            #expect(letters[0].id == "F")
        } else {
            Issue.record("Expected success from cache, got failure")
        }
    }

    @Test func loadWithErrors_cacheThrows_returnsError() {
        let cache = InMemoryCache()
        cache.shouldThrowOnLoad = true
        let repo = LetterRepository(resources: EmptyResourceProvider(), cache: cache)
        if case .success = repo.loadWithErrors() {
            Issue.record("Should not succeed when both bundle and cache fail")
        }
    }

    @Test func loadLetters_emptyBundle_cacheFallback_doesNotSaveEmptyToCache() {
        let cache = InMemoryCache(storedLetters: [makeSampleLetter("K")])
        _ = LetterRepository(resources: EmptyResourceProvider(), cache: cache).loadLetters()
        #expect(cache.storedLetters != nil)
        #expect(!(cache.storedLetters?.isEmpty ?? true))
    }

    @Test func letterRepositoryError_equatability() {
        #expect(LetterRepositoryError.noAssetsFound == .noAssetsFound)
        #expect(LetterRepositoryError.partialLoad(loaded: 2, issues: ["A: missing audio"])
             == .partialLoad(loaded: 2, issues: ["A: missing audio"]))
        #expect(LetterRepositoryError.partialLoad(loaded: 2, issues: ["A: missing audio"])
            != .partialLoad(loaded: 3, issues: ["A: missing audio"]))
        #expect(LetterRepositoryError.cacheReadFailed(path: "/tmp/x") == .cacheReadFailed(path: "/tmp/x"))
        #expect(LetterRepositoryError.cacheCorrupted(underlying: "bad JSON") == .cacheCorrupted(underlying: "bad JSON"))
    }
}
