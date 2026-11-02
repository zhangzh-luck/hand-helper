import Foundation

/// Persisted grades returned by GET /api/v1/grades, distinct from import previews.
struct GradeRecord: Codable, Identifiable, Equatable {
    let id: Int
    let termID: Int
    let courseCode: String
    let courseName: String
    let courseType: String?
    let credits: Double?
    let score: String?
    let finalExamScore: String?
    let usualScore: String?
    let gradePoint: Double?
    let weightedGradePoint: Double?
    let examType: String?
    let makeupFlag: Bool
    let retakeFlag: Bool

    enum CodingKeys: String, CodingKey {
        case id, credits, score
        case termID = "term_id", courseCode = "course_code", courseName = "course_name"
        case courseType = "course_type", finalExamScore = "final_exam_score"
        case usualScore = "usual_score", gradePoint = "grade_point"
        case weightedGradePoint = "weighted_grade_point", examType = "exam_type"
        case makeupFlag = "makeup_flag", retakeFlag = "retake_flag"
    }
}

/// The backend owns every statistic and its calculation rules.
struct GradeSummary: Codable, Equatable {
    let totalCourses: Int
    let totalCredits: Double?
    let earnedCredits: Double?
    let failedCourses: Int
    let averageScore: Double?
    let gpa: Double?
    let gpaNote: String?

    enum CodingKeys: String, CodingKey {
        case gpa
        case totalCourses = "total_courses", totalCredits = "total_credits"
        case earnedCredits = "earned_credits", failedCourses = "failed_courses"
        case averageScore = "average_score", gpaNote = "gpa_note"
    }
}

struct GradeAIAnalysis: Codable, Identifiable, Equatable {
    let id: Int?
    let termID: Int
    let content: String
    let provider: String
    let model: String
    let createdAt: String
    let cached: Bool?

    enum CodingKeys: String, CodingKey {
        case id, content, provider, model, cached
        case termID = "term_id", createdAt = "created_at"
    }
}

struct AnalysisTermData: Codable, Equatable {
    var grades: [GradeRecord]
    var summary: GradeSummary
    var history: [GradeAIAnalysis]
}

struct AnalysisSnapshot: Codable, Equatable {
    var terms: [TermInfo]
    var byTerm: [Int: AnalysisTermData]
    var savedAt: Date
}
