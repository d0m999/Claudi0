import Foundation
import ImageIO
import Vision

// Reads only an image already captured through CUA. No screen, AX, application or input APIs.
guard CommandLine.arguments.count == 2,
    let source = CGImageSourceCreateWithURL(
        URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
else { exit(2) }
let request = VNRecognizeTextRequest()
request.usesCPUOnly = true
request.recognitionLevel = .accurate
request.usesLanguageCorrection = false
request.recognitionLanguages = ["zh-Hans", "en-US"]
do {
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    let records: [[String: Any]] = (request.results ?? []).compactMap { observation in
        guard let candidate = observation.topCandidates(1).first else { return nil }
        let box = observation.boundingBox
        return [
            "text": candidate.string, "x": box.midX * Double(image.width),
            "y": (1 - box.midY) * Double(image.height), "confidence": candidate.confidence,
        ]
    }
    FileHandle.standardOutput.write(
        try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys]))
} catch { exit(1) }
