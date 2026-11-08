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

/// Durable server-side analysis work. The app stores only this metadata locally;
/// grades, prompts, credentials, and session cookies never enter the task store.
struct GradeAIJob: Codable, Identifiable, Equatable {
    enum Status: String, Codable, CaseIterable {
        case queued, running, succeeded, failed, cancelled, unknown

        var isActive: Bool { self == .queued || self == .running }

        var displayName: String {
            switch self {
            case .queued: "排队中"
            case .running: "正在分析"
            case .succeeded: "分析完成"
            case .failed: "分析失败"
            case .cancelled: "已取消"
            case .unknown: "状态未知"
            }
        }
    }

    let jobID: String
    let termID: Int
    let inputHash: String
    let provider: String
    let model: String
    let status: Status
    let reused: Bool
    let cached: Bool
    let attempt: Int
    let createdAt: String
    let updatedAt: String
    let startedAt: String?
    let finishedAt: String?
    let errorCode: String?
    let errorMessage: String?
    let analysisID: Int?
    let analysis: GradeAIAnalysis?

    var id: String { jobID }

    enum CodingKeys: String, CodingKey {
        case status, reused, cached, attempt, provider, model, analysis
        case jobID = "job_id", termID = "term_id", inputHash = "input_hash"
        case createdAt = "created_at", updatedAt = "updated_at"
        case startedAt = "started_at", finishedAt = "finished_at"
        case errorCode = "error_code", errorMessage = "error_message"
        case analysisID = "analysis_id"
    }
}

/// Stored before the create request is sent so a dropped response can be
/// replayed with the same idempotency key instead of creating another paid job.
struct PersistedGradeAIJob: Codable, Equatable, Identifiable {
    let termID: Int
    let idempotencyKey: String
    let forceRefresh: Bool
    var job: GradeAIJob?
    let createdAt: Date

    var id: String { job?.jobID ?? idempotencyKey }
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
