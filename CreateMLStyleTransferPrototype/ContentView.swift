//
//  ContentView.swift
//  CreateMLStyleTransferPrototype
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var datasetManager = DatasetManager()
    @StateObject private var trainer = StyleTransferTrainer()
    @StateObject private var modelTester = ModelTester()

    @State private var styleImage: NSImage?
    @State private var isDraggingStyle = false
    @State private var config = TrainingConfiguration()
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            trainingTab
                .tabItem { Label("Train", systemImage: "brain") }
                .tag(0)

            testingTab
                .tabItem { Label("Test", systemImage: "photo") }
                .tag(1)
        }
        .frame(minWidth: 900, minHeight: 700)
    }

    // MARK: - Training Tab

    private var trainingTab: some View {
        HSplitView {
            // Left: Configuration
            configurationPanel
                .frame(minWidth: 300, maxWidth: 350)

            // Right: Training Status
            trainingStatusPanel
        }
        .padding()
    }

    private var configurationPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Style Transfer Training")
                    .font(.title)

                // Dataset Section
                GroupBox("Content Dataset") {
                    datasetSection
                }

                // Style Image Section
                GroupBox("Style Image") {
                    styleImageSection
                }

                // Parameters Section
                GroupBox("Training Parameters") {
                    parametersSection
                }

                // Train Button
                trainButton
            }
            .padding()
        }
    }

    private var datasetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                datasetStatusView
                Spacer()
                downloadButton
            }
        }
    }

    @ViewBuilder
    private var datasetStatusView: some View {
        switch datasetManager.cocoDatasetState {
        case .notDownloaded:
            Label("Not downloaded", systemImage: "xmark.circle")
                .foregroundColor(.secondary)
        case .downloading(let progress):
            if let progress = progress {
                HStack {
                    ProgressView(value: progress)
                        .frame(width: 100)
                    Text("\(Int(progress * 100))%")
                }
            } else {
                HStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Downloading...")
                }
            }
        case .ready(let count):
            Label("\(count) images ready", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundColor(.red)
        }
    }

    @ViewBuilder
    private var downloadButton: some View {
        if case .notDownloaded = datasetManager.cocoDatasetState {
            Button("Download") {
                datasetManager.downloadCOCODataset()
            }
        } else if case .error = datasetManager.cocoDatasetState {
            Button("Retry") {
                datasetManager.downloadCOCODataset()
            }
        }
    }

    private var styleImageSection: some View {
        VStack {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isDraggingStyle ? Color.accentColor : Color.clear, lineWidth: 2)
                    )

                if let image = styleImage {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                } else {
                    VStack {
                        Image(systemName: "photo.badge.plus")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("Drop style image here")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .frame(height: 200)
            .onDrop(of: [.image, .fileURL], isTargeted: $isDraggingStyle) { providers in
                handleStyleImageDrop(providers: providers)
            }

            HStack {
                Button("Choose File...") {
                    chooseStyleImage()
                }
                if styleImage != nil {
                    Button("Clear") {
                        styleImage = nil
                    }
                }
            }
        }
    }

    private var parametersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Algorithm
            Picker("Algorithm", selection: $config.algorithm) {
                ForEach(TrainingConfiguration.Algorithm.allCases) { algo in
                    Text(algo.rawValue).tag(algo)
                }
            }

            // Iterations
            HStack {
                Text("Iterations:")
                TextField("", value: $config.maxIterations, format: .number)
                    .frame(width: 80)
                Stepper("", value: $config.maxIterations, in: 100...2000, step: 100)
                    .labelsHidden()
            }

            // Textel Density
            HStack {
                Text("Detail Level:")
                Slider(value: Binding(
                    get: { Double(config.textelDensity) },
                    set: { config.textelDensity = Int($0) - Int($0) % 4 }
                ), in: 64...512, step: 4)
                Text("\(config.textelDensity)")
                    .frame(width: 40)
            }

            // Style Strength
            HStack {
                Text("Style Strength:")
                Slider(value: Binding(
                    get: { Double(config.styleStrength) },
                    set: { config.styleStrength = Int($0) }
                ), in: 1...25, step: 1)
                Text("\(config.styleStrength)")
                    .frame(width: 30)
            }
        }
    }

    private var trainButton: some View {
        Button(action: startTraining) {
            HStack {
                Image(systemName: "play.fill")
                Text("Start Training")
            }
            .frame(maxWidth: .infinity)
            .padding()
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canStartTraining)
    }

    private var canStartTraining: Bool {
        let datasetReady: Bool
        if case .ready = datasetManager.cocoDatasetState {
            datasetReady = true
        } else {
            datasetReady = false
        }

        return styleImage != nil && datasetReady && config.isValid && !trainer.isTraining
    }

    // MARK: - Training Status Panel

    private var trainingStatusPanel: some View {
        VStack(spacing: 20) {
            Text("Training Status")
                .font(.title2)

            if trainer.isTraining {
                trainingProgressView
            } else if let model = trainer.trainedModel {
                trainedModelView(model)
            } else if let error = trainer.error {
                errorView(error)
            } else {
                placeholderView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.gray.opacity(0.05))
    }

    private var trainingProgressView: some View {
        VStack(spacing: 16) {
            ProgressView(value: trainer.progress)
                .progressViewStyle(.linear)
                .frame(width: 300)

            Text("\(Int(trainer.progress * 100))% complete")
                .font(.headline)

            Text("Iteration \(trainer.currentIteration) of \(config.maxIterations)")
                .foregroundColor(.secondary)

            if let validationImage = trainer.validationPreview {
                Text("Validation Preview")
                    .font(.caption)
                Image(nsImage: validationImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 300, maxHeight: 300)
                    .cornerRadius(8)
            }

            Button("Cancel") {
                trainer.cancelTraining()
            }
            .buttonStyle(.bordered)
        }
    }

    private func trainedModelView(_ modelURL: URL) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)

            Text("Training Complete!")
                .font(.headline)

            Text(modelURL.lastPathComponent)
                .foregroundColor(.secondary)

            HStack {
                Button("Export Model...") {
                    exportModel(modelURL)
                }

                Button("Test Model") {
                    modelTester.loadModel(from: modelURL)
                    selectedTab = 1
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func errorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 60))
                .foregroundColor(.red)

            Text("Training Failed")
                .font(.headline)

            Text(error)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var placeholderView: some View {
        VStack(spacing: 16) {
            Image(systemName: "brain")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("Configure training and click Start")
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Testing Tab

    private var testingTab: some View {
        ModelTestingView(tester: modelTester)
    }

    // MARK: - Actions

    private func chooseStyleImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            styleImage = NSImage(contentsOf: url)
        }
    }

    private func handleStyleImageDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                if let data = data, let image = NSImage(data: data) {
                    DispatchQueue.main.async {
                        styleImage = image
                    }
                }
            }
            return true
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil),
                   let image = NSImage(contentsOf: url) {
                    DispatchQueue.main.async {
                        styleImage = image
                    }
                }
            }
            return true
        }

        return false
    }

    private func startTraining() {
        guard let image = styleImage else { return }

        Task {
            await trainer.train(
                styleImage: image,
                contentDirectory: datasetManager.contentDirectoryURL,
                configuration: config
            )
        }
    }

    private func exportModel(_ modelURL: URL) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "mlmodel")!]
        panel.nameFieldStringValue = modelURL.lastPathComponent

        if panel.runModal() == .OK, let destination = panel.url {
            try? FileManager.default.copyItem(at: modelURL, to: destination)
        }
    }
}

#Preview {
    ContentView()
}
