import Foundation

enum TranscriptStitcher {
    nonisolated private static let maximumOverlapWordCount = 30
    nonisolated private static let minimumFragmentLength = 2
    nonisolated private static let nonAlphanumerics = CharacterSet.alphanumerics.inverted

    nonisolated static func merged(_ existing: [String], _ next: [String]) -> [String] {
        guard !existing.isEmpty else { return next }
        guard !next.isEmpty else { return existing }

        let limit = min(maximumOverlapWordCount, existing.count, next.count)
        guard let overlap = stride(from: limit, through: 1, by: -1).first(where: {
            overlapMatches(tail: Array(existing.suffix($0)), head: Array(next.prefix($0)))
        }) else {
            return existing + next
        }

        var result = existing
        if isPrefixFragment(result[result.count - 1], of: next[overlap - 1]) {
            result[result.count - 1] = next[overlap - 1]
        }
        return result + next.dropFirst(overlap)
    }

    nonisolated private static func overlapMatches(tail: [String], head: [String]) -> Bool {
        let allowsFragmentEdges = tail.count >= 2
        var comparedWord = false

        for index in tail.indices {
            switch (normalized(tail[index]), normalized(head[index])) {
            case (nil, nil):
                continue
            case let (tailWord?, headWord?):
                comparedWord = true
                if tailWord == headWord { continue }
                if allowsFragmentEdges, index == tail.startIndex,
                   isSuffixFragment(headWord, of: tailWord) {
                    continue
                }
                if allowsFragmentEdges, index == tail.index(before: tail.endIndex),
                   isPrefixFragment(tailWord, of: headWord) {
                    continue
                }
                return false
            default:
                return false
            }
        }
        return comparedWord
    }

    nonisolated private static func isPrefixFragment(_ fragment: String, of word: String) -> Bool {
        guard let fragment = normalized(fragment), let word = normalized(word) else { return false }
        return fragment.count >= minimumFragmentLength && word.count > fragment.count && word.hasPrefix(fragment)
    }

    nonisolated private static func isSuffixFragment(_ fragment: String, of word: String) -> Bool {
        guard let fragment = normalized(fragment), let word = normalized(word) else { return false }
        return fragment.count >= minimumFragmentLength && word.count > fragment.count && word.hasSuffix(fragment)
    }

    nonisolated private static func normalized(_ word: String) -> String? {
        let value = word.lowercased().trimmingCharacters(in: nonAlphanumerics)
        return value.isEmpty ? nil : value
    }
}
