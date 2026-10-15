import Foundation

extension Date {
    /// "오후 3:12" today, "수" this week, "10/12" earlier — for the sidebar.
    var abbreviated: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        let calendar = Calendar.current
        if calendar.isDateInToday(self) {
            formatter.setLocalizedDateFormatFromTemplate("a h:mm")
        } else if calendar.isDate(self, equalTo: Date(), toGranularity: .weekOfYear) {
            formatter.setLocalizedDateFormatFromTemplate("EEE")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("M/d")
        }
        return formatter.string(from: self)
    }

    /// "방금", "5분 전", "3시간 전", 아니면 날짜.
    var timeAgoShort: String {
        let seconds = Int(-timeIntervalSinceNow)
        switch seconds {
        case ..<60: return "방금"
        case ..<3600: return "\(seconds / 60)분 전"
        case ..<86400: return "\(seconds / 3600)시간 전"
        default:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ko_KR")
            formatter.setLocalizedDateFormatFromTemplate("M/d a h:mm")
            return formatter.string(from: self)
        }
    }
}
