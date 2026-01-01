//
//  ModelTestingView.swift
//  CreateMLStyleTransferPrototype
//

import SwiftUI
import UniformTypeIdentifiers

struct ModelTestingView: View {
    @ObservedObject var tester: ModelTester
    @State private var isDraggingInput = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Test Trained Model")
                .font(.title)

            // Model loading section
            HStack {
                if tester.modelLoaded {
                    Label(tester.modelName ?? "Model loaded", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else if tester.isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading model...")
                } else {
                    Text("No model loaded")
                        .foregroundColor(.secondary)
                }

                Spacer()

                Button("Load Model...") {
                    tester.loadModelFromFile()
                }
            }
            .padding(.horizontal)

            if let error = tester.error {
                Text(error)
                    .foregroundColor(.red)
                    .padding()
            }

            // Image panels
            HStack(spacing: 20) {
                // Input image
                VStack {
                    Text("Input")
                        .font(.headline)

                    imageDropZone(
                        image: tester.inputImage?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                        placeholder: "Drop test image here",
                        isDragging: $isDraggingInput
                    )
                    .onDrop(of: [.image, .fileURL], isTargeted: $isDraggingInput) { providers in
                        handleImageDrop(providers: providers)
                    }

                    Button("Choose Image...") {
                        chooseInputImage()
                    }
                }

                // Output image
                VStack {
                    Text("Styled Output")
                        .font(.headline)

                    ZStack {
                        imageDropZone(
                            image: tester.outputImage,
                            placeholder: "Output will appear here",
                            isDragging: .constant(false)
                        )

                        if tester.isProcessing {
                            ProgressView()
                                .scaleEffect(1.5)
                                .background(Color.black.opacity(0.3))
                        }
                    }

                    Button("Apply Style") {
                        tester.processImage()
                    }
                    .disabled(!tester.modelLoaded || tester.inputImage == nil || tester.isProcessing)
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func imageDropZone(image: CGImage?, placeholder: String, isDragging: Binding<Bool>) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isDragging.wrappedValue ? Color.accentColor : Color.clear, lineWidth: 2)
                )

            if let cgImage = image {
                Image(decorative: cgImage, scale: 1.0)
                    .resizable()
                    .scaledToFit()
                    .padding(4)
            } else {
                VStack {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text(placeholder)
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(width: 400, height: 400)
    }

    private func chooseInputImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            tester.inputImage = NSImage(contentsOf: url)
        }
    }

    private func handleImageDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                if let data = data, let image = NSImage(data: data) {
                    DispatchQueue.main.async {
                        tester.inputImage = image
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
                        tester.inputImage = image
                    }
                }
            }
            return true
        }

        return false
    }
}
