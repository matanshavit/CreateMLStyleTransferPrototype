//
//  DatasetManager.swift
//  CreateMLStyleTransferPrototype
//

import Foundation
import CreateML
import Combine

@MainActor
class DatasetManager: ObservableObject {
    enum DatasetSource: String, CaseIterable, Identifiable {
        case apple = "Apple Built-in (~600 images)"
        case coco = "COCO Dataset (subset)"

        var id: String { rawValue }
    }

    enum DatasetState: Equatable {
        case notDownloaded
        case downloading(progress: Double?)  // nil = indeterminate
        case ready(imageCount: Int)
        case error(String)
    }

    @Published var appleDatasetState: DatasetState = .notDownloaded
    @Published var cocoDatasetState: DatasetState = .notDownloaded
    @Published var selectedSource: DatasetSource = .apple

    private let fileManager = FileManager.default
    private var cocoDownloader: COCODownloader?

    var contentDirectoryURL: URL? {
        switch selectedSource {
        case .apple:
            return appleContentDirectory
        case .coco:
            return cocoContentDirectory
        }
    }

    private var appleContentDirectory: URL? {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport.appendingPathComponent("CreateMLStyleTransferPrototype/AppleContent")
    }

    private var cocoContentDirectory: URL? {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return appSupport.appendingPathComponent("CreateMLStyleTransferPrototype/COCOContent")
    }

    init() {
        checkExistingDatasets()
    }

    func checkExistingDatasets() {
        // Check Apple dataset
        if let dir = appleContentDirectory, fileManager.fileExists(atPath: dir.path) {
            let count = countImages(in: dir)
            appleDatasetState = count > 0 ? .ready(imageCount: count) : .notDownloaded
        }

        // Check COCO dataset
        if let dir = cocoContentDirectory, fileManager.fileExists(atPath: dir.path) {
            let count = countImages(in: dir)
            cocoDatasetState = count > 0 ? .ready(imageCount: count) : .notDownloaded
        }
    }

    private func countImages(in directory: URL) -> Int {
        let extensions = ["jpg", "jpeg", "png"]
        guard let contents = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return 0
        }
        return contents.filter { url in
            extensions.contains(url.pathExtension.lowercased())
        }.count
    }

    func downloadAppleDataset() {
        guard let targetDir = appleContentDirectory else {
            appleDatasetState = .error("Could not create directory")
            return
        }

        // Show indeterminate loading state (Apple API doesn't provide progress)
        appleDatasetState = .downloading(progress: nil)

        // Run download on background thread to avoid blocking UI
        Task.detached { [weak self] in
            do {
                // Create directory if needed
                try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

                // Use MLStyleTransfer's built-in asset download
                try await MLStyleTransfer.downloadAssets()

                // Update state on main actor
                await MainActor.run {
                    // Apple's downloadAssets() doesn't copy to a user-accessible location
                    // The assets are available internally for training
                    self?.appleDatasetState = .ready(imageCount: 600)
                }
            } catch {
                await MainActor.run {
                    self?.appleDatasetState = .error("Download failed: \(error.localizedDescription)")
                }
            }
        }
    }

    func downloadCOCODataset() {
        guard let targetDir = cocoContentDirectory else {
            cocoDatasetState = .error("Could not create directory")
            return
        }

        do {
            try fileManager.createDirectory(at: targetDir, withIntermediateDirectories: true)
        } catch {
            cocoDatasetState = .error("Could not create directory: \(error.localizedDescription)")
            return
        }

        cocoDatasetState = .downloading(progress: 0)

        // COCO val2017 dataset URL
        let cocoURL = URL(string: "http://images.cocodataset.org/zips/val2017.zip")!

        // Use delegate-based download for real progress tracking
        cocoDownloader = COCODownloader(
            url: cocoURL,
            targetDirectory: targetDir,
            onProgress: { [weak self] progress in
                Task { @MainActor in
                    self?.cocoDatasetState = .downloading(progress: progress)
                }
            },
            onComplete: { [weak self] result in
                Task { @MainActor in
                    switch result {
                    case .success(let count):
                        self?.cocoDatasetState = .ready(imageCount: count)
                    case .failure(let error):
                        self?.cocoDatasetState = .error("Download failed: \(error.localizedDescription)")
                    }
                    self?.cocoDownloader = nil
                }
            }
        )
        cocoDownloader?.start()
    }
}

// MARK: - COCO Downloader with real progress tracking

private class COCODownloader: NSObject, URLSessionDownloadDelegate {
    private let url: URL
    private let targetDirectory: URL
    private let onProgress: (Double) -> Void
    private let onComplete: (Result<Int, Error>) -> Void
    private var session: URLSession?

    init(url: URL, targetDirectory: URL, onProgress: @escaping (Double) -> Void, onComplete: @escaping (Result<Int, Error>) -> Void) {
        self.url = url
        self.targetDirectory = targetDirectory
        self.onProgress = onProgress
        self.onComplete = onComplete
        super.init()
    }

    func start() {
        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        session?.downloadTask(with: url).resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            onProgress(progress)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            // Unzip and extract first 600 images
            let count = try extractImages(from: location, to: targetDirectory, limit: 600)
            onComplete(.success(count))
        } catch {
            onComplete(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            onComplete(.failure(error))
        }
    }

    private func extractImages(from zipURL: URL, to targetDir: URL, limit: Int) throws -> Int {
        // Use Process to unzip (macOS has built-in unzip)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", "-j", zipURL.path, "-d", targetDir.path]

        try process.run()
        process.waitUntilExit()

        let fileManager = FileManager.default

        // Limit to specified number of images
        if let contents = try? fileManager.contentsOfDirectory(at: targetDir, includingPropertiesForKeys: nil) {
            let images = contents.filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
            if images.count > limit {
                for imageURL in images.dropFirst(limit) {
                    try? fileManager.removeItem(at: imageURL)
                }
            }
            return min(images.count, limit)
        }

        return 0
    }
}
