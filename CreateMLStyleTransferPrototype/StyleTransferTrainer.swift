//
//  StyleTransferTrainer.swift
//  CreateMLStyleTransferPrototype
//

import Foundation
import CreateML
import CoreML
import AppKit
import Combine

@MainActor
class StyleTransferTrainer: ObservableObject {
    @Published var isTraining = false
    @Published var progress: Double = 0
    @Published var currentIteration: Int = 0
    @Published var validationPreview: NSImage?
    @Published var trainedModel: URL?
    @Published var error: String?

    private var trainingJob: MLJob<MLStyleTransfer>?
    private var cancellables = Set<AnyCancellable>()

    private var outputDirectory: URL? {
        let fileManager = FileManager.default
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = appSupport.appendingPathComponent("CreateMLStyleTransferPrototype/TrainedModels")
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var sessionDirectory: URL? {
        let fileManager = FileManager.default
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = appSupport.appendingPathComponent("CreateMLStyleTransferPrototype/TrainingSessions")
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func train(
        styleImage: NSImage,
        contentDirectory: URL?,
        configuration: TrainingConfiguration
    ) async {
        // Reset state
        isTraining = true
        progress = 0
        currentIteration = 0
        validationPreview = nil
        trainedModel = nil
        error = nil
        cancellables.removeAll()

        do {
            // Save style image to temp file
            guard let styleURL = saveStyleImage(styleImage) else {
                throw TrainingError.failedToSaveStyleImage
            }

            // Create data source
            let dataSource: MLStyleTransfer.DataSource
            if let contentDir = contentDirectory {
                dataSource = MLStyleTransfer.DataSource.images(
                    styleImage: styleURL,
                    contentDirectory: contentDir,
                    processingOption: nil
                )
            } else {
                // Use Apple's built-in content dataset
                // Note: This requires downloadAssets() to have been called
                dataSource = MLStyleTransfer.DataSource.images(
                    styleImage: styleURL,
                    contentDirectory: contentDirectory!, // Will use downloaded assets
                    processingOption: nil
                )
            }

            // Create validation image from style image for preview
            let validationURL = styleURL // Use style image as validation for simplicity

            // Configure model parameters
            let modelParams = MLStyleTransfer.ModelParameters(
                algorithm: configuration.algorithm.mlAlgorithm,
                validation: .content(validationURL),
                maxIterations: configuration.maxIterations,
                textelDensity: configuration.textelDensity,
                styleStrength: configuration.styleStrength
            )

            // Configure session for checkpoints
            guard let sessionDir = sessionDirectory else {
                throw TrainingError.failedToCreateSessionDirectory
            }

            let sessionParams = MLTrainingSessionParameters(
                sessionDirectory: sessionDir,
                reportInterval: 5,
                checkpointInterval: 50,
                iterations: configuration.maxIterations
            )

            // Start training
            let job = try MLStyleTransfer.train(
                trainingData: dataSource,
                parameters: modelParams,
                sessionParameters: sessionParams
            )

            self.trainingJob = job

            // Monitor progress
            job.progress
                .publisher(for: \.fractionCompleted)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] fraction in
                    self?.progress = fraction
                    self?.currentIteration = Int(fraction * Double(configuration.maxIterations))
                }
                .store(in: &cancellables)

            // Handle completion
            let model = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MLStyleTransfer, Error>) in
                job.result
                    .sink(
                        receiveCompletion: { completion in
                            if case .failure(let error) = completion {
                                continuation.resume(throwing: error)
                            }
                        },
                        receiveValue: { model in
                            continuation.resume(returning: model)
                        }
                    )
                    .store(in: &self.cancellables)
            }

            // Save trained model
            guard let outputDir = outputDirectory else {
                throw TrainingError.failedToCreateOutputDirectory
            }

            let timestamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let modelName = "StyleTransfer_\(timestamp).mlmodel"
            let modelURL = outputDir.appendingPathComponent(modelName)

            try model.write(to: modelURL)

            trainedModel = modelURL
            isTraining = false

        } catch {
            self.error = error.localizedDescription
            isTraining = false
        }
    }

    func cancelTraining() {
        trainingJob?.cancel()
        isTraining = false
        error = "Training cancelled"
    }

    private func saveStyleImage(_ image: NSImage) -> URL? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        let tempDir = FileManager.default.temporaryDirectory
        let styleURL = tempDir.appendingPathComponent("style_image.png")

        do {
            try pngData.write(to: styleURL)
            return styleURL
        } catch {
            return nil
        }
    }

    enum TrainingError: LocalizedError {
        case failedToSaveStyleImage
        case failedToCreateSessionDirectory
        case failedToCreateOutputDirectory

        var errorDescription: String? {
            switch self {
            case .failedToSaveStyleImage:
                return "Failed to save style image to temporary file"
            case .failedToCreateSessionDirectory:
                return "Failed to create training session directory"
            case .failedToCreateOutputDirectory:
                return "Failed to create output directory for trained model"
            }
        }
    }
}
