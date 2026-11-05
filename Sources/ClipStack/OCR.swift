import Foundation
import Vision
import ImageIO

/// On-device text & barcode recognition using Apple's Vision framework (100% offline).
enum OCR {
    struct AnalysisResult {
        let text: String
        let qrPayload: String?
    }

    static func analyze(url: URL) async -> AnalysisResult {
        await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                return AnalysisResult(text: "", qrPayload: nil)
            }
            return analyze(cgImage: cg)
        }.value
    }

    static func analyze(cgImage: CGImage) -> AnalysisResult {
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        textRequest.automaticallyDetectsLanguage = true

        let barcodeRequest = VNDetectBarcodesRequest()

        do {
            try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([textRequest, barcodeRequest])
        } catch {
            return AnalysisResult(text: "", qrPayload: nil)
        }

        let lines = (textRequest.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        let text = lines.joined(separator: "\n")

        let qrPayload = (barcodeRequest.results ?? []).compactMap { $0.payloadStringValue }.first

        return AnalysisResult(text: text, qrPayload: qrPayload)
    }

    static func recognize(url: URL) async -> String {
        await analyze(url: url).text
    }

    static func recognize(cgImage: CGImage) -> String {
        analyze(cgImage: cgImage).text
    }
}
