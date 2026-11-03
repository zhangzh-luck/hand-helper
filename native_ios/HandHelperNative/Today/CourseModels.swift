import Foundation

// The server returns expanded timetable sessions. Keep their wire names here so
// Today and the future timetable page use the same model.
struct CourseSession: Codable, Equatable, Identifiable {
    let id: Int
    let name: String
    let date: String
    let startDateTime: String
    let endDateTime: String
    let room: String?
    let teacher: String?
    let weekExpression: String?
    let source: String?
    let manualCourseID: Int?
    let termID: Int?
    let weekday: Int?
    let startPeriod: Int?
    let endPeriod: Int?

    enum CodingKeys: String, CodingKey {
        case id, teacher, source, weekday
        case name = "course_name"
        case date = "session_date"
        case startDateTime = "start_datetime"
        case endDateTime = "end_datetime"
        case room = "classroom"
        case weekExpression = "week_expression"
        case manualCourseID = "manual_course_id"
        case termID = "term_id"
        case startPeriod = "start_period"
        case endPeriod = "end_period"
    }

    var start: Date? { BackendDate.parse(startDateTime) }
    var end: Date? { BackendDate.parse(endDateTime) }
}

// Flutter stores these rules locally and expands them using term start dates
// and period times. This schema is shared with the future timetable editor.
struct ManualCourseRule: Codable, Equatable, Identifiable {
    let id: Int
    let termSourceID: String
    let name: String
    let weeks: [Int]
    let weekday: Int
    let startPeriod: Int
    let endPeriod: Int
    let room: String?
    let teacher: String?
    let remoteID: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, weeks, weekday, room, teacher
        case termSourceID = "term_source_id"
        case startPeriod = "start_period"
        case endPeriod = "end_period"
        case remoteID = "remote_id"
    }
}

struct CustomSchedule: Codable, Equatable, Identifiable {
    let id: Int
    let title: String
    let date: String
    let time: String
    let endTime: String?

    init(id: Int, title: String, date: String, time: String, endTime: String? = nil) {
        self.id = id
        self.title = title
        self.date = date
        self.time = time
        self.endTime = endTime
    }

    enum CodingKeys: String, CodingKey {
        case id, title
        case date = "scheduled_date"
        case time = "scheduled_time"
        case endTime = "end_time"
    }
}

struct TodayProfile: Codable, Equatable {
    var displayName: String
    var avatarDataURL: String?
    var homeWallpaperDataURL: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case avatarDataURL = "avatar_data_url"
        case homeWallpaperDataURL = "home_wallpaper_data_url"
    }
}

enum BackendDate {
    static func parse(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        let standard = ISO8601DateFormatter()
        if let date = standard.date(from: raw) { return date }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        local.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return local.date(from: raw)
    }
}
