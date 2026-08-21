import Foundation
struct ApiEnvelope<T:Decodable>:Decodable { let success:Bool;let data:T?;let error:ApiError?;let requestId:String; enum CodingKeys:String,CodingKey{case success,data,error;case requestId="request_id"} }
struct ApiError:Decodable { let code:String;let message:String }
struct CourseSession:Decodable,Identifiable { let id:Int;let courseName:String;let startDatetime:Date;let endDatetime:Date; enum CodingKeys:String,CodingKey{case id;case courseName="course_name";case startDatetime="start_datetime";case endDatetime="end_datetime"} }
