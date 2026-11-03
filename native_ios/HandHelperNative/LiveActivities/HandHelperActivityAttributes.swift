import ActivityKit
import Foundation

struct HandHelperActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let kind: String
        let title: String
        let start: Date
        let end: Date
        let location: String?
    }

    let itemID: String
}
