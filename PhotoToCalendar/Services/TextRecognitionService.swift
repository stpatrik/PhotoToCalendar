//
//  TextRecognitionService.swift
//  PhotoToCalendar
//
//  Created by Georgy on 24.09.2025.
//

import UIKit
import Vision

final class TextRecognitionService {
    static let shared = TextRecognitionService()
    private init() {}
    
    // Старый метод — оставляем, чтобы не ломать вызовы (возвращает только текст)
    func recognizeLines(in image: UIImage, languages: [String]) async throws -> [String] {
        let positioned = try await recognizePositionedLines(in: image, languages: languages)
        return positioned.map { $0.text }
    }
    
    // Новый метод: возвращает текст + позицию (rect в нормализованных координатах Vision)
    func recognizePositionedLines(in image: UIImage, languages: [String]) async throws -> [OCRLine] {
        guard let cg = image.cgImage else { return [] }
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = languages
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.02
        
        try handler.perform([request])
        let observations = request.results ?? []
        
        var result: [OCRLine] = []
        for ob in observations {
            guard let top = ob.topCandidates(1).first else { continue }
            let text = normalize(top.string)
            guard !text.isEmpty else { continue }
            // VNRecognizedTextObservation.boundingBox — нормализованный rect (origin в левом нижнем углу).
            let rect = ob.boundingBox
            result.append(OCRLine(text: text, rect: rect))
        }
        // Сортировка сверху-вниз, слева-направо для стабильности
        return result.sorted { a, b in
            if abs(a.rect.midY - b.rect.midY) > 0.01 {
                return a.rect.midY > b.rect.midY // выше (большее Y) раньше
            } else {
                return a.rect.minX < b.rect.minX
            }
        }
    }
    
    private func normalize(_ s: String) -> String {
        s.replacingOccurrences(of: "–", with: "-")
         .replacingOccurrences(of: "—", with: "-")
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
