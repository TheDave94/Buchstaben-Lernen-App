import UIKit
import SwiftUI
import CoreText
import CoreGraphics

/// Renders a single letter using the Primae-Regular OTF font into a UIImage.
/// Dark-gray glyph on transparent background.
/// Results are cached by letter+size to avoid redundant renders.
/// Cache is capped at 52 entries (26 letters × 2 common display sizes) to
/// prevent unbounded memory growth across letter/layout changes.
@MainActor
public enum PrimaeLetterRenderer {

    // MARK: - Cache

    private struct CacheKey: Hashable {
        let letter:     String
        let width:      Int
        let height:     Int
        // schriftArt is part of the key so two scripts can coexist
        // in the cache without a race window after a script switch.
        let schriftArt: SchriftArt
        // OpenType feature tags applied to the font (e.g. "ss02" for
        // the curled-k variant). Sorted+joined so order doesn't churn.
        let features:   String
    }

    private struct RectCacheKey: Hashable {
        let letter:     String
        let width:      Int
        let height:     Int
        let schriftArt: SchriftArt
        let features:   String
    }

    private static var cache: [CacheKey: UIImage] = [:]
    private static var rectCache: [RectCacheKey: CGRect] = [:]
    /// Holds 59 letters × ~3 common cell sizes × 2 OT-feature variants.
    private static let cacheLimit = 360

    // MARK: - Public API

    /// Map a `(letter, schriftArt, variant)` triple to the OpenType
    /// feature tags that swap in the alternate glyph. Today only the
    /// Druckschrift lowercase k has an alternate (ss02 → curled-k).
    public static func openTypeFeatures(for letter: String,
                                        schriftArt: SchriftArt,
                                        variant: Bool) -> [String] {
        guard variant else { return [] }
        if schriftArt == .druckschrift && letter == "k" { return ["ss02"] }
        return []
    }

    public static func render(letter: String,
                              size: CGSize,
                              schriftArt: SchriftArt = .druckschrift,
                              openTypeFeatures: [String] = []) -> UIImage? {
        guard size.width > 0, size.height > 0, !letter.isEmpty else { return nil }
        // CGDataProvider hangs in the test process — skip rendering.
        guard !isRunningTests else { return nil }
        let key = CacheKey(letter: letter,
                            width: Int(size.width),
                            height: Int(size.height),
                            schriftArt: schriftArt,
                            features: openTypeFeatures.sorted().joined(separator: ","))
        if let cached = cache[key] { return cached }
        guard let image = draw(letter: letter, size: size,
                               fontName: schriftArt.fontFileName,
                               openTypeFeatures: openTypeFeatures) else { return nil }
        // Full eviction when over cap — letters rarely change and the
        // next render repopulates the one entry that matters.
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = image
        return image
    }

    public static func clearCache() {
        cache.removeAll()
        rectCache.removeAll()
    }

    /// Output of `renderWord`: the whole word as one text run (so
    /// Schreibschrift ligatures connect) plus per-character bounding
    /// boxes for positioning per-cell overlays.
    public struct WordRendering {
        public let image: UIImage
        public let characterFrames: [CGRect]
    }

    /// Render an entire word as one cursive text run. Defaults to
    /// Schreibschrift; Druckschrift words work fine per-letter.
    /// Returns nil in tests or when the font/glyphs are unavailable.
    public static func renderWord(word: String, size: CGSize,
                                  schriftArt: SchriftArt = .schreibschrift) -> WordRendering? {
        guard size.width > 0, size.height > 0, !word.isEmpty else { return nil }
        guard !isRunningTests else { return nil }

        let scale: CGFloat = 2.0
        let px = CGSize(width: size.width * scale, height: size.height * scale)

        // Probe at a large size to measure the line, then scale so the line
        // fits the canvas with 10% padding on both axes.
        let probe: CGFloat = 600
        guard let probeFont = makeFont(size: probe, fontName: schriftArt.fontFileName) else { return nil }
        let probeAttrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): probeFont
        ]
        let probeString = NSAttributedString(string: word, attributes: probeAttrs)
        let probeLine = CTLineCreateWithAttributedString(probeString as CFAttributedString)
        var probeAscent: CGFloat = 0
        var probeDescent: CGFloat = 0
        var probeLeading: CGFloat = 0
        let probeWidth = CTLineGetTypographicBounds(probeLine, &probeAscent, &probeDescent, &probeLeading)
        let probeHeight = probeAscent + probeDescent
        guard probeWidth > 0, probeHeight > 0 else { return nil }

        let pad: CGFloat = 0.10
        let availW = px.width  * (1 - 2 * pad)
        let availH = px.height * (1 - 2 * pad)
        let ratio  = min(availW / probeWidth, availH / probeHeight)
        let finalSize = probe * ratio

        // Build the final-size line with the final-size font.
        guard let font = makeFont(size: finalSize, fontName: schriftArt.fontFileName) else { return nil }
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font
        ]
        let attrString = NSAttributedString(string: word, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attrString as CFAttributedString)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let lineWidth = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
        let lineHeight = ascent + descent
        guard lineWidth > 0, lineHeight > 0 else { return nil }

        // Center the line in the px canvas. offsetX is where x=0 of the
        // CTLine coordinate space maps to in the image; offsetY (in the
        // bottom-left CT coord system) is the baseline position.
        let offsetX = (px.width - lineWidth) / 2
        let baselineY = (px.height - lineHeight) / 2 + descent

        // Extract per-character frames in UIKit (top-origin) canvas coords.
        var characterFrames: [CGRect] = []
        let runsArray = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        for run in runsArray {
            let glyphCount = CTRunGetGlyphCount(run)
            guard glyphCount > 0 else { continue }
            var positions = [CGPoint](repeating: .zero, count: glyphCount)
            var advances  = [CGSize](repeating: .zero,  count: glyphCount)
            CTRunGetPositions(run, CFRange(location: 0, length: glyphCount), &positions)
            CTRunGetAdvances(run,  CFRange(location: 0, length: glyphCount), &advances)
            for i in 0..<glyphCount {
                let pxFrame = CGRect(
                    // CT reports glyph positions relative to the line origin
                    // (x baseline start, y baseline).
                    x: offsetX + positions[i].x,
                    // Top of the glyph cell in UIKit coords = image height
                    // minus the baseline minus ascent.
                    y: px.height - (baselineY + ascent),
                    width: advances[i].width,
                    height: lineHeight
                )
                characterFrames.append(CGRect(
                    x: pxFrame.minX / scale,
                    y: pxFrame.minY / scale,
                    width: pxFrame.width / scale,
                    height: pxFrame.height / scale
                ))
            }
        }

        // Draw the line into a bitmap context. CoreText uses bottom-left
        // origin; we flip the context so the emitted image has top-left
        // origin consistent with UIKit.
        guard let ctx = CGContext(
            data: nil,
            width: Int(px.width), height: Int(px.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).rawValue
        ) else { return nil }

        ctx.clear(CGRect(origin: .zero, size: px))
        ctx.setFillColor(UIColor(red: 30/255, green: 30/255, blue: 30/255, alpha: 200/255).cgColor)
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: offsetX, y: baselineY)
        CTLineDraw(line, ctx)

        guard let cgImage = ctx.makeImage() else { return nil }
        let image = UIImage(cgImage: cgImage, scale: scale, orientation: .up)
        return WordRendering(image: image, characterFrames: characterFrames)
    }
    /// Returns the glyph as a SwiftUI `Path` centred in `size` with
    /// 10 % padding. Top-left origin so the caller can pass it straight
    /// to `Canvas` / `.fill(_:)` without transformation.
    public static func glyphPath(letter: String, size: CGSize,
                                 schriftArt: SchriftArt = .druckschrift,
                                 openTypeFeatures: [String] = []) -> Path? {
        guard size.width > 0, size.height > 0, !letter.isEmpty,
              !isRunningTests else { return nil }
        let probe: CGFloat = 800
        guard let font = makeFont(size: probe, fontName: schriftArt.fontFileName,
                                  openTypeFeatures: openTypeFeatures),
              var glyph = getGlyph(for: letter, in: font) else { return nil }
        let bbox = CTFontGetBoundingRectsForGlyphs(font, .default, &glyph, nil, 1)
        guard bbox.width > 0, bbox.height > 0,
              let cgPath = CTFontCreatePathForGlyph(font, glyph, nil) else { return nil }
        // Uniform font-metric scaling against the em-square keeps
        // lowercase 'a' visibly smaller than uppercase 'A'. The glyph
        // sits on the baseline with the inked ascent above and
        // descent below.
        let pad: CGFloat = 0.10
        let availH = size.height * (1 - 2 * pad)
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let emHeight = ascent + descent
        let scale = emHeight > 0 ? availH / emHeight : availH / bbox.height
        // Baseline sits at the bottom of the inked ascent area:
        // 10 % top pad + ascent, all measured in canvas pixels.
        let baselineY = size.height * pad + ascent * scale
        // CoreText positions glyphs with the baseline at y = 0 (BL
        // origin) and the bbox extending up by `bbox.maxY` and down
        // by `bbox.minY` (negative for descenders). Flip Y to UIKit
        // (TL origin) and place the baseline at `baselineY`.
        var transform = CGAffineTransform.identity
            .translatedBy(x: size.width / 2, y: baselineY)
            .scaledBy(x: scale, y: -scale)
            .translatedBy(x: -bbox.midX, y: 0)
        guard let positioned = cgPath.copy(using: &transform) else { return nil }
        return Path(positioned)
    }

    /// Glyph ink bounding rect as fraction of `canvasSize` (cell-fraction
    /// coords). Uses the same em-height scaling and baseline placement as
    /// `glyphPath`, so the rect lines up with the on-screen ghost glyph.
    /// Stroke JSON checkpoints are stored bbox-relative; the canvas maps
    /// them through this rect to get cell-fraction screen positions.
    /// Memoized — the canvas calls this 3× per 60 fps frame.
    public static func normalizedGlyphRect(for letter: String, canvasSize: CGSize,
                                           schriftArt: SchriftArt = .druckschrift,
                                           openTypeFeatures: [String] = []) -> CGRect? {
        guard !isRunningTests, !letter.isEmpty,
              canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        let key = RectCacheKey(letter: letter,
                               width: Int(canvasSize.width),
                               height: Int(canvasSize.height),
                               schriftArt: schriftArt,
                               features: openTypeFeatures.sorted().joined(separator: ","))
        if let cached = rectCache[key] { return cached }
        let probe: CGFloat = 800
        guard let font = makeFont(size: probe, fontName: schriftArt.fontFileName,
                                  openTypeFeatures: openTypeFeatures),
              var glyph = getGlyph(for: letter, in: font) else { return nil }
        let bbox = CTFontGetBoundingRectsForGlyphs(font, .default, &glyph, nil, 1)
        guard bbox.width > 0, bbox.height > 0 else { return nil }
        let pad: CGFloat = 0.10
        let availH = canvasSize.height * (1 - 2 * pad)
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let emHeight = ascent + descent
        let scale = emHeight > 0 ? availH / emHeight : availH / bbox.height
        let baselineY = canvasSize.height * pad + ascent * scale
        let scaledW = bbox.width * scale
        let leftX = canvasSize.width / 2 - scaledW / 2
        let topY = baselineY - (bbox.minY + bbox.height) * scale
        let bottomY = baselineY - bbox.minY * scale
        let rect = CGRect(
            x: leftX / canvasSize.width,
            y: topY / canvasSize.height,
            width: scaledW / canvasSize.width,
            height: (bottomY - topY) / canvasSize.height
        )
        if rectCache.count >= cacheLimit { rectCache.removeAll(keepingCapacity: true) }
        rectCache[key] = rect
        return rect
    }

    // MARK: - Private

    private static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
    }

    static func makeFont(size: CGFloat, fontName: String = "Primae-Regular",
                         openTypeFeatures: [String] = []) -> CTFont? {
        let bundles: [Bundle] = [.module, .main]
        // Try root, then SPM .copy("Resources") nested paths, then flat Fonts/.
        let subdirs: [String?] = [nil, "Resources/Fonts", "Fonts"]
        // Primae is OTF, Playwrite AT is variable TTF — probe both so
        // `schriftArt.fontFileName` can stay extension-agnostic.
        let exts = ["otf", "ttf"]
        for bundle in bundles {
            for subdir in subdirs {
                for ext in exts {
                    let url: URL?
                    if let subdir {
                        url = bundle.url(forResource: fontName, withExtension: ext, subdirectory: subdir)
                    } else {
                        url = bundle.url(forResource: fontName, withExtension: ext)
                    }
                    guard let url,
                          let dataProvider = CGDataProvider(url: url as CFURL),
                          let cgFont       = CGFont(dataProvider) else { continue }
                    let baseFont = CTFontCreateWithGraphicsFont(cgFont, size, nil, nil)
                    return applyOpenTypeFeatures(to: baseFont, tags: openTypeFeatures)
                }
            }
        }
        return nil
    }

    /// Returns a CTFont with the given OpenType feature tags enabled.
    /// `kCTFontOpenTypeFeatureTag` accepts modern 4-char tags like
    /// `"ss02"`; selector value `1` enables the feature.
    private static func applyOpenTypeFeatures(to font: CTFont, tags: [String]) -> CTFont {
        guard !tags.isEmpty else { return font }
        let settings: [[String: Any]] = tags.map {
            [kCTFontOpenTypeFeatureTag as String: $0,
             kCTFontOpenTypeFeatureValue as String: 1]
        }
        let attributes: [String: Any] = [
            kCTFontFeatureSettingsAttribute as String: settings
        ]
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(
            CTFontCopyFontDescriptor(font),
            attributes as CFDictionary
        )
        return CTFontCreateWithFontDescriptor(descriptor, CTFontGetSize(font), nil)
    }

    static func getGlyph(for letter: String, in font: CTFont) -> CGGlyph? {
        // NFC-normalise so umlauts arrive as precomposed codepoints
        // (ä = U+00E4); decomposed pairs would silently render the
        // base letter. Walk every UTF-16 unit so surrogate pairs work.
        let normalised = letter.precomposedStringWithCanonicalMapping
        for unit in normalised.utf16 {
            var c = unit
            var g = CGGlyph(0)
            if CTFontGetGlyphsForCharacters(font, &c, &g, 1), g != 0 {
                return g
            }
        }
        return nil
    }

    private static func draw(letter: String, size: CGSize, fontName: String = "Primae-Regular",
                             openTypeFeatures: [String] = []) -> UIImage? {
        let scale: CGFloat = 2.0
        let px = CGSize(width: size.width * scale, height: size.height * scale)

        // Probe at large size to compute scale factor
        let probe: CGFloat = 800
        guard let probeFont = makeFont(size: probe, fontName: fontName,
                                       openTypeFeatures: openTypeFeatures),
              var probeGlyph = getGlyph(for: letter, in: probeFont) else { return nil }

        let probeBBox = CTFontGetBoundingRectsForGlyphs(probeFont, .default, &probeGlyph, nil, 1)
        guard probeBBox.width > 0, probeBBox.height > 0 else { return nil }

        let pad: CGFloat = 0.10
        let availW    = px.width  * (1 - 2 * pad)
        let availH    = px.height * (1 - 2 * pad)
        let finalSize = probe * min(availW / probeBBox.width, availH / probeBBox.height)

        guard let font = makeFont(size: finalSize, fontName: fontName,
                                  openTypeFeatures: openTypeFeatures),
              var glyph = getGlyph(for: letter, in: font) else { return nil }

        let bbox = CTFontGetBoundingRectsForGlyphs(font, .default, &glyph, nil, 1)
        guard bbox.width > 0, bbox.height > 0 else { return nil }

        let offsetX = (px.width  - bbox.width)  / 2 - bbox.minX
        let offsetY = (px.height - bbox.height) / 2 - bbox.minY

        guard let ctx = CGContext(
            data: nil,
            width: Int(px.width), height: Int(px.height),
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).rawValue
        ) else { return nil }

        ctx.clear(CGRect(origin: .zero, size: px))
        ctx.setFillColor(UIColor(red: 30/255, green: 30/255, blue: 30/255, alpha: 200/255).cgColor)
        ctx.translateBy(x: offsetX, y: offsetY)

        guard let path = CTFontCreatePathForGlyph(font, glyph, nil) else { return nil }
        ctx.addPath(path)
        ctx.fillPath()

        guard let cgImage = ctx.makeImage() else { return nil }
        return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
    }
}
