import Foundation
import Vision

// On-device OCR with Vision: accurate recognition, automatic language
// detection, one line per recognised text observation. Used for image clip
// titles and for capturing text from the screen.
nonisolated enum TextRecognizer {
  /// Runs on the global concurrent executor so the main thread stays free.
  /// Returns nil if the image can't be read, "" if it contains no text.
  @concurrent
  static func recognizeText(imageData: Data) async -> String? {
    let requestHandler = VNImageRequestHandler(data: imageData)
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.automaticallyDetectsLanguage = true

    do {
      try requestHandler.perform([request])
    } catch {
      print("Unable to perform the request: \(error).")
      return nil
    }

    guard let observations = request.results else {
      return nil
    }

    return observations
      .compactMap { $0.topCandidates(1).first?.string }
      .joined(separator: "\n")
  }
}
