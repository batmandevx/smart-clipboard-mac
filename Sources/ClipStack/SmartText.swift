import AppKit
import CoreImage
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
        case 3:
            r = CGFloat((hexNumber & 0xF00) >> 8) / 15.0
            g = CGFloat((hexNumber & 0x0F0) >> 4) / 15.0
            b = CGFloat(hexNumber & 0x00F) / 15.0
            a = 1.0
        case 6:
            r = CGFloat((hexNumber & 0xFF0000) >> 16) / 255.0
            g = CGFloat((hexNumber & 0x00FF00) >> 8) / 255.0
            b = CGFloat(hexNumber & 0x0000FF) / 255.0
            a = 1.0
        case 8:
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

    /// Minifies JSON
    static func minifyJSON(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) ||
              (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")),
              let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []),
              let minData = try? JSONSerialization.data(withJSONObject: json, options: []),
              let result = String(data: minData, encoding: .utf8) else {
            return nil
        }
        return result
    }

    /// Word, character, and line stats
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

    /// Base64 detection and conversions
    static func isBase64(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4, trimmed.count % 4 == 0,
              let data = Data(base64Encoded: trimmed),
              let decoded = String(data: data, encoding: .utf8),
              !decoded.isEmpty else { return false }
        return true
    }

    static func toBase64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    static func fromBase64(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed),
              let decoded = String(data: data, encoding: .utf8) else { return nil }
        return decoded
    }

    /// URL encoding/decoding
    static func urlEncode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
    }

    static func urlDecode(_ text: String) -> String {
        text.removingPercentEncoding ?? text
    }

    /// Strip HTML tags
    static func stripHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    /// Strip Markdown styling
    static func stripMarkdown(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(of: "```[a-zA-Z]*\\n", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "```", with: "")
        result = result.replacingOccurrences(of: "`([^`]+)`", with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: "^#{1,6}\\s+", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "(\\*\\*|__)(.*?)\\1", with: "$2", options: .regularExpression)
        result = result.replacingOccurrences(of: "(\\*|_)(.*?)\\1", with: "$2", options: .regularExpression)
        result = result.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^\\)]+\\)", with: "$1", options: .regularExpression)
        return result
    }

    // MARK: - Sensitive Data Masking

    struct SensitiveInfo {
        let type: String
        let masked: String
    }

    static func detectSensitive(in text: String) -> SensitiveInfo? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        // OpenAI API Key
        if trimmed.hasPrefix("sk-") && trimmed.count >= 20 {
            let prefix = String(trimmed.prefix(7))
            let suffix = String(trimmed.suffix(4))
            return SensitiveInfo(type: "OpenAI API Key", masked: "\(prefix)••••••••••••\(suffix)")
        }

        // GitHub Token
        if (trimmed.hasPrefix("ghp_") || trimmed.hasPrefix("gho_") || trimmed.hasPrefix("github_pat_")) && trimmed.count >= 25 {
            let prefix = String(trimmed.prefix(4))
            let suffix = String(trimmed.suffix(4))
            return SensitiveInfo(type: "GitHub Token", masked: "\(prefix)••••••••••••\(suffix)")
        }

        // AWS Access Key ID
        if trimmed.hasPrefix("AKIA") && trimmed.count == 20 {
            let prefix = String(trimmed.prefix(4))
            let suffix = String(trimmed.suffix(4))
            return SensitiveInfo(type: "AWS Access Key", masked: "\(prefix)••••••••••••\(suffix)")
        }

        // Stripe Live Key
        if trimmed.hasPrefix("sk_live_") && trimmed.count >= 24 {
            let prefix = String(trimmed.prefix(8))
            let suffix = String(trimmed.suffix(4))
            return SensitiveInfo(type: "Stripe Key", masked: "\(prefix)••••••••••••\(suffix)")
        }

        // Private Key Block
        if trimmed.contains("-----BEGIN") && trimmed.contains("PRIVATE KEY-----") {
            return SensitiveInfo(type: "Private Key", masked: "-----BEGIN •••• PRIVATE KEY----- [MASKED]")
        }

        // Credit Card Number (13 to 19 digits with optional spaces or dashes)
        let digitsOnly = trimmed.filter { $0.isNumber }
        if (13...19).contains(digitsOnly.count) &&
           (trimmed.allSatisfy { $0.isNumber || $0 == " " || $0 == "-" }) {
            let suffix = String(digitsOnly.suffix(4))
            return SensitiveInfo(type: "Payment Card", masked: "•••• •••• •••• \(suffix)")
        }

        return nil
    }

    // MARK: - QR Code Generator

    static func generateQRCode(from string: String) -> NSImage? {
        guard !string.isEmpty,
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let outputCIImage = filter.outputImage else { return nil }

        let transform = CGAffineTransform(scaleX: 10, y: 10)
        let scaledImage = outputCIImage.transformed(by: transform)
        let rep = NSCIImageRep(ciImage: scaledImage)
        let nsImage = NSImage(size: rep.size)
        nsImage.addRepresentation(rep)
        return nsImage
    }

    // MARK: - Image Compression & Conversion

    static func compressImage(data: Data, quality: CGFloat = 0.75, scale: CGFloat = 1.0) -> Data? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }

        if scale < 1.0 {
            let newWidth = max(Int(CGFloat(rep.pixelsWide) * scale), 10)
            let newHeight = max(Int(CGFloat(rep.pixelsHigh) * scale), 10)
            guard let resized = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: newWidth, pixelsHigh: newHeight,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0
            ) else { return nil }

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: resized)
            rep.draw(in: NSRect(x: 0, y: 0, width: newWidth, height: newHeight))
            NSGraphicsContext.restoreGraphicsState()

            return resized.representation(using: .jpeg, properties: [.compressionFactor: quality])
        }

        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    static func convertToPNG(data: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Merge Clips

    static func mergeClips(_ clips: [ClipItem], separator: String = "\n\n") -> String {
        clips.compactMap { $0.text ?? $0.ocrText }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: separator)
    }
}
