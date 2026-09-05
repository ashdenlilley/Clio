import Foundation

enum WritingTime {
    static func label(words: Int, wordsPerMinute: Int) -> String {
        guard words > 0, wordsPerMinute > 0 else { return "0s" }
        let seconds = Int(ceil(Double(words) * 60 / Double(wordsPerMinute)))
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes == 0 { return "\(remainder)s" }
        return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(remainder)s"
    }
}
