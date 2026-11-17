import Foundation

/// A fixed, non-personal payload for the first-stage App Group experiment.
enum WidgetProbeStore {
    static let groupID = "group.5e7e951f5e3f59e7.1"
    static let kind = "HandHelperTodayCourseProbe"
    static let payload = "共享容器测试成功（非真实课程）"
    private static let fileName = "widget-probe-v1.txt"

    enum Result: Equatable {
        case success, containerUnavailable, missing, invalid, failed
    }

    static func container() -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
    }

    static func write(to directory: URL?) -> Result {
        guard let directory else { return .containerUnavailable }
        do {
            try Data(payload.utf8).write(to: directory.appendingPathComponent(fileName), options: .atomic)
            return .success
        } catch { return .failed }
    }

    static func read(from directory: URL?) -> Result {
        guard let directory else { return .containerUnavailable }
        let file = directory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: file.path) else { return .missing }
        do {
            let data = try Data(contentsOf: file)
            return data == Data(payload.utf8) ? .success : .invalid
        } catch { return .failed }
    }
}
