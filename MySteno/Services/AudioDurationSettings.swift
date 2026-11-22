import Foundation
import Observation

enum AudioFormatConfiguration {
    nonisolated static let sampleRate = 16_000.0
    nonisolated static let defaultMaximumDurationMinutes = 30
    nonisolated static let memoryWarningDurationMinutes = 60

    nonisolated static func maximumCaptureSampleCount(
        for duration: TimeInterval
    ) -> Int {
        let protectedDuration = duration * 1.01 + 1
        let sampleCount = sampleRate * protectedDuration
        guard sampleCount.isFinite, sampleCount < Double(Int.max) else {
            return Int.max
        }
        return max(1, Int(sampleCount.rounded(.down)))
    }

    nonisolated static func initialSampleReservation(
        maximumSampleCount: Int
    ) -> Int {
        let warningThresholdSampleCount = Int(
            sampleRate * TimeInterval(memoryWarningDurationMinutes * 60)
        )
        return min(maximumSampleCount, warningThresholdSampleCount)
    }

    nonisolated static func elapsedLabel(for duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    nonisolated static func limitDescription(minutes: Int) -> String {
        if minutes.isMultiple(of: 60) {
            let hours = minutes / 60
            return "\(hours) \(hours == 1 ? "hour" : "hours")"
        }
        return "\(minutes) minutes"
    }
}

@Observable
final class AudioDurationSettings {
    private static let maximumDurationMinutesKey = "maximumAudioDurationMinutes"

    private(set) var maximumDurationMinutes: Int

    @ObservationIgnored private let userDefaults = UserDefaults.standard

    init() {
        let storedMinutes = userDefaults.integer(
            forKey: Self.maximumDurationMinutesKey
        )
        maximumDurationMinutes = storedMinutes > 0
            ? storedMinutes
            : AudioFormatConfiguration.defaultMaximumDurationMinutes
    }

    var maximumDuration: TimeInterval {
        TimeInterval(maximumDurationMinutes) * 60
    }

    var limitDescription: String {
        AudioFormatConfiguration.limitDescription(minutes: maximumDurationMinutes)
    }

    var showsMemoryWarning: Bool {
        maximumDurationMinutes > AudioFormatConfiguration.memoryWarningDurationMinutes
    }

    @discardableResult
    func updateMaximumDurationMinutes(_ minutes: Int) -> Bool {
        guard minutes > 0 else { return false }
        maximumDurationMinutes = minutes
        userDefaults.set(minutes, forKey: Self.maximumDurationMinutesKey)
        return true
    }
}

struct RecordingTimeline: Sendable {
    let startedAt: Date
    let maximumDuration: TimeInterval

    init(startedAt: Date, maximumDuration: TimeInterval) {
        precondition(maximumDuration > 0)
        self.startedAt = startedAt
        self.maximumDuration = maximumDuration
    }

    func elapsed(at date: Date) -> TimeInterval {
        max(0, date.timeIntervalSince(startedAt))
    }

    func hasReachedLimit(at date: Date) -> Bool {
        elapsed(at: date) >= maximumDuration
    }
}
