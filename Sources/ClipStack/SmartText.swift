import AppKit
import Foundation

enum SmartText {
    /// Detects if text is a valid web URL
    static func url(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else { return nil }
        return URL(string: trimmed)
    }

    /// Detects if text is a hex color (e.g. #FF5733, #FFF, #10B981FF)
    static func color(from text: String) -> NSColor? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard [3, 4, 6, 8].contains(trimmed.count),
              let hexNumber = UInt64(trimmed, radix: 16) else { return nil }

        let r, g, b, a: CGFloat
        switch trimmed.count {
        case 3: // RGB
            r = CGFloat((hexNumber & 0xF00) >> 8) / 15.0
            g = CGFloat((hexNumber & 0x0F0) >> 4) / 15.0
            b = CGFloat(hexNumber & 0x00F) / 15.0
            a = 1.0
        case 6: // RRGGBB
            r = CGFloat((hexNumber & 0xFF0000) >> 16) / 255.0
            g = CGFloat((hexNumber & 0x00FF00) >> 8) / 255.0
            b = CGFloat(hexNumber & 0x0000FF) / 255.0
            a = 1.0
        case 8: // RRGGBBAA
            r = CGFloat((hexNumber & 0xFF000000) >> 24) / 255.0
            g = CGFloat((hexNumber & 0x00FF0000) >> 16) / 255.0
            b = CGFloat((hexNumber & 0x0000FF00) >> 8) / 255.0
            a = CGFloat(hexNumber & 0x000000FF) / 255.0
        default:
            return nil
        }
        return NSColor(red: r, green: g, blue: b, alpha: a)
    }

    /// Formats an NSColor into Hex string
    static func hexString(from color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Detects and beautifies JSON
    static func prettyJSON(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) ||
              (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")),
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let prettyData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
              let result = String(data: prettyData, encoding: .utf8) else {
            return nil
        }
        return result
    }

    /// Word and character stats
    static func stats(for text: String) -> (words: Int, chars: Int, lines: Int) {
        let chars = text.count
        let words = text.split { $0.isWhitespace || $0.isNewline }.count
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        return (words, chars, lines)
    }

    /// Case conversions
    static func toCamelCase(_ text: String) -> String {
        let words = text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard let first = words.first else { return text }
        return first.lowercased() + words.dropFirst().map(\.capitalized).joined()
    }

    static func toSnakeCase(_ text: String) -> String {
        let words = text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return words.map { $0.lowercased() }.joined(separator: "_")
    }

    static func toKebabCase(_ text: String) -> String {
        let words = text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return words.map { $0.lowercased() }.joined(separator: "-")
    }
}
