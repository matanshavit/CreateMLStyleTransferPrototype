//
//  ModelTester.swift
//  CreateMLStyleTransferPrototype
//

import Foundation
import CoreML
import CoreImage
import Vision
import AppKit
import UniformTypeIdentifiers
import Combine

@MainActor
class ModelTester: ObservableObject {
    @Published var isLoading = false
    @Published var modelLoaded = false
    @Published var modelName: String?
    @Published var error: String?
    @Published var inputImage: NSImage?
    @Published var outputImage: CGImage?
    @Published var isProcessing = false

    private var model: MLModel?
    private var visionModel: VNCoreMLModel?
    private let ciContext = CIContext()

    func loadModel(from url: URL) {
        isLoading = true
        error = nil
        modelLoaded = false

        Task {
            do {
                let config = MLModelConfiguration()
                config.computeUnits = .all

                // Compile if needed
                let compiledURL: URL
                if url.pathExtension == "mlmodel" {
                    compiledURL = try await MLModel.compileModel(at: url)
                } else {
                    compiledURL = url
                }

                model = try MLModel(contentsOf: compiledURL, configuration: config)
                visionModel = try VNCoreMLModel(for: model!)

                modelName = url.deletingPathExtension().lastPathComponent
                modelLoaded = true
                isLoading = false
            } catch {
                self.error = "Failed to load model: \(error.localizedDescription)"
                isLoading = false
            }
        }
    }

    func loadModelFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "mlmodel")!,
            UTType(filenameExtension: "mlmodelc")!,
            UTType(filenameExtension: "mlpackage")!
        ]
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            loadModel(from: url)
        }
    }

    func processImage() {
        guard let model = model,
              let inputImage = inputImage,
              let cgImage = inputImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }

        isProcessing = true
        error = nil
        outputImage = nil

        Task {
            do {
                // Use Vision framework for Create ML models (outputs CVPixelBuffer)
                if let visionModel = visionModel {
                    let output = try await processWithVision(cgImage: cgImage, model: visionModel)
                    outputImage = output
                } else {
                    // Fallback to direct CoreML inference
                    let output = try await processWithCoreML(cgImage: cgImage, model: model)
                    outputImage = output
                }

                isProcessing = false
            } catch {
                self.error = "Processing failed: \(error.localizedDescription)"
                isProcessing = false
            }
        }
    }

    private func processWithVision(cgImage: CGImage, model: VNCoreMLModel) async throws -> CGImage {
        return try await withCheckedThrowingContinuation { continuation in
            let request = VNCoreMLRequest(model: model) { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }

                // Create ML style transfer outputs VNPixelBufferObservation
                if let results = request.results as? [VNPixelBufferObservation],
                   let observation = results.first {
                    let ciImage = CIImage(cvPixelBuffer: observation.pixelBuffer)
                    if let cgImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent) {
                        continuation.resume(returning: cgImage)
                        return
                    }
                }

                continuation.resume(throwing: ProcessingError.failedToGetOutput)
            }

            request.imageCropAndScaleOption = .scaleFill

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func processWithCoreML(cgImage: CGImage, model: MLModel) async throws -> CGImage {
        // Create pixel buffer from CGImage
        guard let pixelBuffer = createPixelBuffer(from: cgImage, size: CGSize(width: 512, height: 512)) else {
            throw ProcessingError.failedToCreatePixelBuffer
        }

        // Run inference
        let inputFeature = try MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(pixelBuffer: pixelBuffer)
        ])

        let output = try await model.prediction(from: inputFeature)

        // Get output - Create ML models output CVPixelBuffer via imageBufferValue
        if let featureValue = output.featureValue(for: "stylizedImage"),
           let outputBuffer = featureValue.imageBufferValue {
            let ciImage = CIImage(cvPixelBuffer: outputBuffer)
            if let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) {
                return cgImage
            }
        }

        throw ProcessingError.failedToGetOutput
    }

    private func createPixelBuffer(from cgImage: CGImage, size: CGSize) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }

        context.draw(cgImage, in: CGRect(origin: .zero, size: size))
        return buffer
    }

    enum ProcessingError: LocalizedError {
        case failedToCreatePixelBuffer
        case failedToGetOutput

        var errorDescription: String? {
            switch self {
            case .failedToCreatePixelBuffer:
                return "Failed to create pixel buffer from image"
            case .failedToGetOutput:
                return "Failed to get output from model"
            }
        }
    }
}
