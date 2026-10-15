// Recognize the text in screenshots (Vision) and print one "file name<TAB>text" per line. Used for the truncation check (check-truncation.sh)
// Usage: swift ocr.swift image...  or compile and run
import AppKit
import Vision

for path in CommandLine.arguments.dropFirst() {
    guard let image = NSImage(contentsOfFile: path), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        print("\(path)\t<cannot read image>")
        continue
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false  // do not "correct" truncated words back to the full word
    request.automaticallyDetectsLanguage = true
    try? VNImageRequestHandler(cgImage: cg).perform([request])
    let name = (path as NSString).lastPathComponent
    for observation in request.results ?? [] {
        if let text = observation.topCandidates(1).first?.string { print("\(name)\t\(text)") }
    }
}
