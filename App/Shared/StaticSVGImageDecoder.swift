import Foundation
import AppKit
import CoreGraphics

/// Subconjunto SVG estático: rechaza documentos fuera de la política y devuelve solo raster.
/// El dibujo AppKit es síncrono; la cancelación evita publicar el resultado, no interrumpe el dibujo.
enum StaticSVGImageDecoder {
    static let maximumInputBytes = 256 * 1_024
    static let maximumElements = 2_048
    static let maximumDepth = 32
    static let maximumAttributes = 64
    static let maximumAttributeBytes = 32_768
    static let maximumTextBytes = 16_384
    static let maximumNumbers = 16_384
    static let maximumPathSegments = 2_048
    static let maximumCoordinate = 1_000_000.0
    static let maximumIntrinsicDimension = 65_536.0

    static func image(from data: Data, maxPixels: Int) -> CGImage? {
        guard !Task.isCancelled, validated(data) else { return nil }
        return autoreleasepool {
            guard !Task.isCancelled, let image = NSImage(data: data),
                  acceptableSize(image.size.width, image.size.height) else { return nil }
            image.cacheMode = .never
            let maximum = min(4_096, max(1, maxPixels))
            let ratio = Double(maximum) / max(image.size.width, image.size.height)
            let width = max(1, min(maximum, Int((image.size.width * ratio).rounded())))
            let height = max(1, min(maximum, Int((image.size.height * ratio).rounded())))
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bitmapFormat: [], bytesPerRow: width * 4,
                bitsPerPixel: 32
            ), let context = NSGraphicsContext(bitmapImageRep: bitmap),
               let bytes = bitmap.bitmapData else { return nil }
            memset(bytes, 0, bitmap.bytesPerRow * height)
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            image.draw(in: NSRect(x: 0, y: 0, width: width, height: height),
                       from: .zero, operation: .copy, fraction: 1)
            context.flushGraphics()
            guard !Task.isCancelled else { return nil }
            return bitmap.cgImage
        }
    }

    static func validated(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= maximumInputBytes,
              let text = String(data: data, encoding: .utf8), !text.contains("\0") else { return false }
        let lower = text.lowercased()
        guard !lower.contains("<!doctype"), !lower.contains("<!entity") else { return false }
        let validator = Validator(), parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.allowedExternalEntityURLs = []
        parser.delegate = validator
        return parser.parse() && validator.finished()
    }

    private static func acceptableSize(_ width: Double, _ height: Double) -> Bool {
        width.isFinite && height.isFinite && width >= 0.01 && height >= 0.01
            && width <= maximumIntrinsicDimension && height <= maximumIntrinsicDimension
            && max(width, height) / min(width, height) <= 1_024
    }

    private static let number = try! NSRegularExpression(pattern: #"[-+]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][-+]?[0-9]+)?"#)
    private static let identifier = try! NSRegularExpression(pattern: #"^[A-Za-z_][A-Za-z0-9_.:\-]{0,127}$"#)
    private static func identifierValid(_ text: String) -> Bool {
        identifier.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
    private static func scalar(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = number.firstMatch(in: trimmed, range: range), match.range == range,
              let value = Double(trimmed), value.isFinite, abs(value) <= maximumCoordinate else { return nil }
        return value
    }
    private static func numberList(_ text: String) -> [Double]? {
        var cursor = NumberCursor(text)
        var result: [Double] = []
        cursor.skipWhitespace()
        while !cursor.atEnd {
            guard let value = cursor.takeNumber() else { return nil }
            result.append(value)
            guard result.count <= maximumNumbers else { return nil }
            let separated = cursor.skipWhitespace()
            if cursor.take(",") {
                cursor.skipWhitespace()
                guard !cursor.atEnd else { return nil }
            } else if !cursor.atEnd && !separated { return nil }
        }
        return result
    }
    private struct NumberCursor {
        let text: String
        var index: String.Index
        init(_ text: String) { self.text = text; index = text.startIndex }
        var atEnd: Bool { index == text.endIndex }
        var current: Character? { atEnd ? nil : text[index] }
        @discardableResult mutating func skipWhitespace() -> Bool {
            let start = index
            while !atEnd && " \t\r\n".contains(text[index]) { index = text.index(after: index) }
            return start != index
        }
        mutating func take(_ character: Character) -> Bool {
            guard current == character else { return false }
            index = text.index(after: index); return true
        }
        mutating func takeNumber() -> Double? {
            let range = NSRange(index..<text.endIndex, in: text)
            guard let match = number.firstMatch(in: text, options: .anchored, range: range),
                  let token = Range(match.range, in: text), let value = scalar(String(text[token])) else { return nil }
            index = token.upperBound; return value
        }
    }
    private static func length(_ text: String, allowPercentage: Bool = true) -> Double? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("px") { value.removeLast(2) }
        else if allowPercentage && value.hasSuffix("%") { value.removeLast() }
        return scalar(value)
    }
    private static func fragment(_ text: String) -> String? {
        guard text.hasPrefix("url(#"), text.hasSuffix(")") else { return nil }
        let id = String(text.dropFirst(5).dropLast())
        return identifierValid(id) ? id : nil
    }
    private static func color(_ text: String) -> Bool {
        let named: Set<String> = ["none", "currentColor", "transparent", "black", "white", "red", "green", "blue", "yellow", "gray", "grey", "silver", "maroon", "purple", "fuchsia", "lime", "olive", "navy", "teal", "aqua", "orange"]
        if named.contains(text) { return true }
        if text.hasPrefix("#") { let hex = text.dropFirst(); return [3, 4, 6, 8].contains(hex.count) && hex.allSatisfy(\.isHexDigit) }
        return false
    }

    private final class Validator: NSObject, XMLParserDelegate {
        private let elements: Set<String> = ["svg", "g", "path", "rect", "circle", "ellipse", "line", "polyline", "polygon", "defs", "linearGradient", "radialGradient", "stop", "clipPath", "title", "desc", "text", "tspan"]
        private let numeric: Set<String> = ["x", "y", "x1", "y1", "x2", "y2", "cx", "cy", "r", "rx", "ry", "fx", "fy", "dx", "dy", "width", "height", "stroke-width", "stroke-miterlimit", "stroke-dashoffset", "letter-spacing", "font-size"]
        private let nonnegative: Set<String> = ["r", "rx", "ry", "width", "height", "stroke-width", "stroke-miterlimit", "font-size"]
        private let opacity: Set<String> = ["opacity", "fill-opacity", "stroke-opacity", "stop-opacity", "offset"]
        private let tokens: [String: Set<String>] = ["version": ["1.0", "1.1", "2.0"], "fill-rule": ["nonzero", "evenodd"], "clip-rule": ["nonzero", "evenodd"], "stroke-linecap": ["butt", "round", "square"], "stroke-linejoin": ["miter", "round", "bevel"], "text-anchor": ["start", "middle", "end"], "dominant-baseline": ["auto", "middle", "central", "alphabetic", "hanging", "text-before-edge", "text-after-edge"], "gradientUnits": ["objectBoundingBox", "userSpaceOnUse"], "clipPathUnits": ["objectBoundingBox", "userSpaceOnUse"], "spreadMethod": ["pad", "reflect", "repeat"], "preserveAspectRatio": ["none", "xMinYMin", "xMidYMin", "xMaxYMin", "xMinYMid", "xMidYMid", "xMaxYMid", "xMinYMax", "xMidYMax", "xMaxYMax", "xMidYMid meet", "xMidYMid slice"]]
        private struct Node { let kind: String; let parent: Int? }
        private var nodes: [Node] = []
        private var stack: [Int] = []
        private var ids: [String: Int] = [:]
        private var references: [(Int, String, String)] = []
        private var failed = false
        private var rootAttributes: [String: String] = [:]
        private var numbers = 0
        private var segments = 0
        private var textBytes = 0

        private func reject(_ parser: XMLParser) { failed = true; parser.abortParsing() }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes attrs: [String: String]) {
            guard !Task.isCancelled, elements.contains(name), namespaceURI == "http://www.w3.org/2000/svg",
                  nodes.count < maximumElements, stack.count < maximumDepth, attrs.count <= maximumAttributes,
                  !(name == "svg" && !nodes.isEmpty) else { return reject(parser) }
            if nodes.isEmpty { guard name == "svg" else { return reject(parser) }; rootAttributes = attrs }
            let index = nodes.count
            nodes.append(Node(kind: name, parent: stack.last)); stack.append(index)
            for (key, value) in attrs {
                guard value.utf8.count <= maximumAttributeBytes else { return reject(parser) }
                if key == "id" {
                    guard identifierValid(value), ids[value] == nil else { return reject(parser) }; ids[value] = index
                } else if numeric.contains(key) {
                    guard let n = length(value, allowPercentage: !(index == 0 && ["width", "height"].contains(key))),
                          !nonnegative.contains(key) || n >= 0,
                          key != "font-size" || n <= 1_024 else { return reject(parser) }
                    numbers += 1
                } else if opacity.contains(key) {
                    guard let n = length(value), n >= 0, n <= (value.hasSuffix("%") ? 100 : 1) else { return reject(parser) }; numbers += 1
                } else if key == "viewBox" {
                    guard index == 0, let n = numberList(value), n.count == 4, acceptableSize(n[2], n[3]) else { return reject(parser) }; numbers += 4
                } else if key == "d" {
                    guard name == "path", let count = path(value) else { return reject(parser) }; numbers += count.0; segments += count.1
                } else if key == "points" || key == "stroke-dasharray" {
                    if key == "stroke-dasharray" && value == "none" { continue }
                    guard let n = numberList(value), !n.isEmpty,
                          key != "points" || n.count % 2 == 0,
                          key != "stroke-dasharray" || n.allSatisfy({ $0 >= 0 }) else { return reject(parser) }; numbers += n.count; segments += key == "points" ? n.count / 2 : 0
                } else if ["fill", "stroke", "stop-color", "clip-path"].contains(key) {
                    if let target = fragment(value), key != "stop-color" {
                        references.append((index, key, target))
                    } else if key == "clip-path" ? value != "none" : !color(value) { return reject(parser) }
                } else if key == "font-family" {
                    guard value.count <= 128, !value.isEmpty,
                          value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || " '-,\"".contains($0)) }) else { return reject(parser) }
                } else if key == "font-weight" {
                    guard ["normal", "bold", "bolder", "lighter"].contains(value) || (scalar(value).map { $0 >= 100 && $0 <= 900 } ?? false) else { return reject(parser) }
                } else if let values = tokens[key] {
                    guard values.contains(value) else { return reject(parser) }
                } else { return reject(parser) }
                guard numbers <= maximumNumbers, segments <= maximumPathSegments else { return reject(parser) }
            }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { if !stack.isEmpty { stack.removeLast() } }
        func parser(_ parser: XMLParser, foundCharacters text: String) {
            textBytes += text.utf8.count
            guard textBytes <= maximumTextBytes else { return reject(parser) }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard let current = stack.last, ["text", "tspan", "title", "desc"].contains(nodes[current].kind) else { return reject(parser) }
            }
        }
        func parser(_ parser: XMLParser, foundCDATA data: Data) {
            guard let text = String(data: data, encoding: .utf8) else { return reject(parser) }; self.parser(parser, foundCharacters: text)
        }
        func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) { reject(parser) }
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { reject(parser) }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { reject(parser) }
        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { reject(parser); return nil }
        func finished() -> Bool {
            guard !failed, !nodes.isEmpty, stack.isEmpty else { return false }
            let viewBox = rootAttributes["viewBox"].flatMap(numberList)
            let width = rootAttributes["width"].flatMap { length($0, allowPercentage: false) } ?? viewBox?[2]
            let height = rootAttributes["height"].flatMap { length($0, allowPercentage: false) } ?? viewBox?[3]
            guard let width, let height, acceptableSize(width, height) else { return false }
            var ancestorsWithReferences: Set<Int> = []
            for (source, _, _) in references {
                var current: Int? = source
                while let position = current {
                    ancestorsWithReferences.insert(position); current = nodes[position].parent
                }
            }
            for (_, attribute, id) in references {
                guard let target = ids[id] else { return false }
                let expected = attribute == "clip-path" ? ["clipPath"] : ["linearGradient", "radialGradient"]
                guard expected.contains(nodes[target].kind), !ancestorsWithReferences.contains(target) else { return false }
            }
            return true
        }

        private func path(_ text: String) -> (Int, Int)? {
            if text.isEmpty || text == "none" { return (0, 0) }
            var cursor = NumberCursor(text)
            var command: Character?, first = true, count = 0, operations = 0
            let arities: [Character: Int] = ["M": 2, "L": 2, "H": 1, "V": 1, "C": 6, "S": 4, "Q": 4, "T": 2, "A": 7]
            cursor.skipWhitespace()
            while !cursor.atEnd {
                var explicitCommand = false
                if let c = cursor.current, c.isASCII && c.isLetter {
                    _ = cursor.take(c)
                    let upper = Character(String(c).uppercased())
                    guard first ? upper == "M" : upper == "Z" || arities[upper] != nil else { return nil }
                    command = upper; first = false; explicitCommand = true
                    if upper == "Z" {
                        command = nil; operations += 1
                        guard operations <= maximumPathSegments else { return nil }
                        cursor.skipWhitespace(); continue
                    }
                }
                guard let c = command, let arity = arities[c] else { return nil }
                for index in 0..<arity {
                    cursor.skipWhitespace()
                    if cursor.take(",") {
                        guard index > 0 || !explicitCommand else { return nil }
                        cursor.skipWhitespace()
                    }
                    if c == "A" && (index == 3 || index == 4) {
                        guard cursor.take("0") || cursor.take("1") else { return nil }
                    } else {
                        guard let value = cursor.takeNumber(), c != "A" || index >= 2 || value >= 0 else { return nil }
                    }
                }
                count += arity; operations += 1
                guard count <= maximumNumbers, operations <= maximumPathSegments else { return nil }
                if c == "M" { command = "L" }
                cursor.skipWhitespace()
            }
            return (count, operations)
        }
    }
}
