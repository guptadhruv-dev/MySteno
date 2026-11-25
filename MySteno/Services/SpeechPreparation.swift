import FluidAudio
import Foundation

nonisolated struct SpeechTimeRange: Equatable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
}

nonisolated struct PreparedSpeech: Sendable {
    let samples: [Float]
    let paragraphRanges: [Range<Int>]

    var isEmpty: Bool {
        paragraphRanges.isEmpty
    }

    var retainedSampleCount: Int {
        paragraphRanges.reduce(0) { $0 + $1.count }
    }
}

enum SpeechPreparation {
    nonisolated private static let paragraphPauseDuration: TimeInterval = 2
    nonisolated private static let minimumPeak: Float = 0.001
    nonisolated private static let minimumRootMeanSquare: Float = 0.0005

    nonisolated static var segmentationConfig: VadSegmentationConfig {
        var config = VadSegmentationConfig.default
        config.minSpeechDuration = 0.05
        config.minSilenceDuration = 0.5
        config.maxSpeechDuration = .infinity
        config.speechPadding = 0.5
        config.negativeThreshold = 0.2
        return config
    }

    nonisolated static func prepared(
        samples: [Float],
        segments: [SpeechTimeRange],
        insertsParagraphBreaks: Bool
    ) -> PreparedSpeech {
        var assembled = paragraphs(
            segments: segments,
            sampleCount: samples.count,
            sampleRate: AudioFormatConfiguration.sampleRate
        )
        if !insertsParagraphBreaks, !assembled.isEmpty {
            assembled = [samples.indices]
        }
        if assembled.isEmpty, hasMeaningfulSignal(samples) {
            assembled = [samples.indices]
        }
        return PreparedSpeech(samples: samples, paragraphRanges: assembled)
    }

    nonisolated private static func paragraphs(
        segments: [SpeechTimeRange],
        sampleCount: Int,
        sampleRate: Double,
        paragraphPauseDuration: TimeInterval = paragraphPauseDuration
    ) -> [Range<Int>] {
        guard sampleCount > 0, sampleRate > 0 else { return [] }

        let ranges = segments.compactMap { segment -> Range<Int>? in
            guard segment.startTime.isFinite, segment.endTime.isFinite else { return nil }
            let start = max(0, min(sampleCount, Int(segment.startTime * sampleRate)))
            let end = max(start, min(sampleCount, Int(segment.endTime * sampleRate)))
            return start < end ? start..<end : nil
        }
        .sorted { $0.lowerBound < $1.lowerBound }

        var speechRanges: [Range<Int>] = []
        for range in ranges {
            if let last = speechRanges.last, range.lowerBound <= last.upperBound {
                speechRanges[speechRanges.count - 1] =
                    last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                speechRanges.append(range)
            }
        }
        guard let first = speechRanges.first else { return [] }

        let paragraphPauseSamples = Int(paragraphPauseDuration * sampleRate)
        var paragraphs: [Range<Int>] = []
        var paragraphStart = 0
        var previousSpeechEnd = first.upperBound

        for range in speechRanges.dropFirst() {
            if range.lowerBound - previousSpeechEnd >= paragraphPauseSamples {
                let cut = previousSpeechEnd + (range.lowerBound - previousSpeechEnd) / 2
                paragraphs.append(paragraphStart..<cut)
                paragraphStart = cut
            }
            previousSpeechEnd = range.upperBound
        }
        paragraphs.append(paragraphStart..<sampleCount)
        return paragraphs
    }

    nonisolated private static func hasMeaningfulSignal(_ samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        var peak: Float = 0
        var squaredSum: Double = 0
        for sample in samples {
            let magnitude = abs(sample)
            peak = max(peak, magnitude)
            squaredSum += Double(sample * sample)
        }
        let rootMeanSquare = Float((squaredSum / Double(samples.count)).squareRoot())
        return peak >= minimumPeak && rootMeanSquare >= minimumRootMeanSquare
    }
}
