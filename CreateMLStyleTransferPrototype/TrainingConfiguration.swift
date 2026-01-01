//
//  TrainingConfiguration.swift
//  CreateMLStyleTransferPrototype
//

import Foundation
import CreateML

struct TrainingConfiguration {
    enum Algorithm: String, CaseIterable, Identifiable {
        case cnn = "CNN (Higher Quality)"
        case cnnLite = "CNN Lite (Faster, Video)"

        var id: String { rawValue }

        var mlAlgorithm: MLStyleTransfer.ModelParameters.ModelAlgorithmType {
            switch self {
            case .cnn: return .cnn
            case .cnnLite: return .cnnLite
            }
        }
    }

    var algorithm: Algorithm = .cnn
    var maxIterations: Int = 500
    var textelDensity: Int = 256  // Must be multiple of 4
    var styleStrength: Int = 10   // Range: 1-25, default 5-15

    // Validation
    var isValid: Bool {
        textelDensity % 4 == 0 && textelDensity >= 64 && textelDensity <= 512 &&
        styleStrength >= 1 && styleStrength <= 25 &&
        maxIterations >= 100 && maxIterations <= 2000
    }
}
