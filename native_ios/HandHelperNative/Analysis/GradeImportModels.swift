import Foundation

/// The complete response item is retained even though this batch presents it read-only.
struct GradeImportItem: Decodable, Equatable {
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
    let sourceGradeID: String

    enum CodingKeys: String, CodingKey {
        case courseCode = "course_code"
        case courseName = "course_name"
        case courseType = "course_type"
        case credits, score
        case finalExamScore = "final_exam_score"
        case usualScore = "usual_score"
        case gradePoint = "grade_point"
        case weightedGradePoint = "weighted_grade_point"
        case examType = "exam_type"
        case makeupFlag = "makeup_flag"
        case retakeFlag = "retake_flag"
        case sourceGradeID = "source_grade_id"
    }
}

struct GradeImportPreview: Decodable, Equatable {
    let sourceTermID: String
    let grades: [GradeImportItem]

    enum CodingKeys: String, CodingKey {
        case sourceTermID = "source_term_id"
        case grades
    }
}

struct PendingGradeImport: Identifiable, Equatable {
    enum Phase: Equatable {
        case uploading
        case ready(GradeImportPreview)
        case failed(String)
    }

    let id: UUID
    let owner: String
    var phase: Phase
}
