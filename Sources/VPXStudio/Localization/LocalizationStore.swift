import Foundation
import VPXCaptureProtocol
import Observation

enum LocalizationKey: String {
    case calibrationLensMismatch
    case checkerboardIntrinsicsExpired
    case solveCheckerboard, checkerboardHelp, checkerboardSolving, checkerboardInvalid, checkerboardIntrinsicsMismatch, checkerboardDegenerate, checkerboardResidualRejected, checkerboardMaximumResidual, checkerboardMeasured
    case depthPass, depthConfidencePass, depthPreviewHelp, depthPreviewFar, depthPreviewMissing, depthPreviewAge
    case temporalMatte, temporalMatteHelp, temporalMatteStrength, temporalMatteDisabled, temporalMatteReset, temporalMatteBlend, temporalMatteReuse
    case poseAlignment, poseAlignmentUnavailable, poseMeasured, poseInterpolated, posePredicted, posePredictionHorizon, posePredictionPositionError, posePredictionRotationError
    case registerStage, registerStageHelp, stageRegistrationMissing, saveCalibration, stageAnchoredAt
    case poseRejected, poseMalformed, poseUnavailable, poseReordered, poseMotionRejected, poseReacquiring
    case copyCameraID
    case calibrationReady, calibrationMissing, calibrationEstimated, calibrationExpired, calibrationFuture, calibrationResidual, calibrationCameraMismatch, calibrationFormatMismatch, calibrationReferenceChanged, calibrationRMSE, calibrationValidated
    case depthConfidence, clockUncertainty, trackingReason
    case qualityNormal, qualityInitializing, qualityExcessiveMotion, qualityInsufficientFeatures, qualityRelocalizing, qualityInterrupted, qualityInterruptionEnded, qualityFailed, qualityDisconnected, qualityMotionUnavailable
    case videoInputStale
    case exportDiagnostics, diagnosticsExportFailed
    case archiveDiagnostics, stopArchive
    case runBenchmark
    case loadScene, loadCalibration, assetImportFailed, focusDistance, qualityProfile, liveFast, liveQuality, reviewCinema
    case clearCalibration
    case resetTrackingOrigin
    case inputEncoding, automaticInput, linearInput, debugPass, compositePass, scenePass, videoPass, mattePass
    case outputProtection, trackingProtection, gpuProtection, unknownInputColor, unsupportedInputFormat
    case formatMeasurements, importBudget, conversionBudget, conversionDuration, budgetMisses
    case pipelineMeasurements, captureReceive, receiveDecode, decodeDuration, renderWait, textureImport
    case captureEncode, networkTransport
    case presentationDelay, capturePresent, poseCaptureAge, residentMemory, knownCopies, bufferReuse, surfaceReuse
    case diagnosticsHistory, noEvents, close, discardedEvents, clock
    case stateCurrent, stateStale, stateUnmeasured, stateLost, stateDegraded, stateEstimated
    case build, calibrate, rehearse, live, record, review
    case mode, stop, sources, iphoneCaptureNode, professionalVideoInput, externalTracking
    case connectLocalCamera, chromaKey, monitor, renderer, tracking, frameRate, latency, gpuFrameTime, droppedFrames, focalLength, inputColor, radialDistortion, videoProfile, stageSpace, clockOffset, networkRTT, networkJitter, clockDrift
    case ready, recording, metalFrameGraph, greenThreshold, edgeSoftness
    case language, appearance, system, light, dark, noInput, noConnectedDevices, connecting, connected, disconnected, primaryCamera
    case startIPhonePairing, pairIPhone, scanQRCode, verificationCode, pairingInstructions, stopPairing
    case preparingMetalRenderer, metalPreviewActive, previewStopped, cameraAccessNotGranted, liveCameraPreviewActive
}

struct LanguageOption: Identifiable {
    let id: String
    let name: String
}

private struct LocalizationCatalog: Decodable {
    struct Language: Decodable, Identifiable {
        let id: String
        let name: String
        let translations: [String: String]
    }

    let languages: [Language]
}

/// Runtime-localizable catalog. Adding a language only requires adding one
/// language object to LocalizationCatalog.json; source code does not need a new enum case.
@MainActor @Observable
final class LocalizationStore {
    private let catalog: LocalizationCatalog

    var selectedLanguageID: String {
        didSet { UserDefaults.standard.set(selectedLanguageID, forKey: "language") }
    }

    var languages: [LanguageOption] {
        catalog.languages.map { LanguageOption(id: $0.id, name: $0.name) }
    }

    init() {
        catalog = Self.loadCatalog()
        let saved = UserDefaults.standard.string(forKey: "language") ?? ""
        selectedLanguageID = catalog.languages.contains(where: { $0.id == saved })
            ? saved
            : (Locale.current.language.languageCode?.identifier == "ja" ? "ja" : "en")
        if !catalog.languages.contains(where: { $0.id == selectedLanguageID }) {
            selectedLanguageID = catalog.languages.first?.id ?? "en"
        }
    }

    func text(_ key: LocalizationKey) -> String {
        let selected = catalog.languages.first(where: { $0.id == selectedLanguageID })
        let english = catalog.languages.first(where: { $0.id == "en" })
        return selected?.translations[key.rawValue]
            ?? english?.translations[key.rawValue]
            ?? key.rawValue
    }

    func trackingReason(_ reason: CaptureQualityEvent.Reason) -> String {
        let key: LocalizationKey = switch reason {
        case .normal: .qualityNormal
        case .initializing: .qualityInitializing
        case .excessiveMotion: .qualityExcessiveMotion
        case .insufficientFeatures: .qualityInsufficientFeatures
        case .relocalizing: .qualityRelocalizing
        case .interrupted: .qualityInterrupted
        case .interruptionEnded: .qualityInterruptionEnded
        case .failed: .qualityFailed
        case .disconnected: .qualityDisconnected
        case .motionUnavailable: .qualityMotionUnavailable
        }
        return text(key)
    }

    private static func loadCatalog() -> LocalizationCatalog {
        guard let url = Bundle.module.url(forResource: "LocalizationCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(LocalizationCatalog.self, from: data) else {
            return LocalizationCatalog(languages: [])
        }
        return catalog
    }
}
