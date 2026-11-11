import XCTest
@testable import HandHelperNative

final class AnalysisReportPresentationTests: XCTestCase {
    func testMarkdownBlocksPreserveHierarchyAndRenderInlineBold() {
        let content = "## 总体情况\n本学期表现 **稳定**。\n\n- **优势**：课程完成度高\n- 继续保持"
        let blocks = AnalysisReportPresentation.blocks(from: content)

        XCTAssertEqual(blocks.map(\.kind), [.heading, .paragraph, .spacer, .bullet, .bullet])
        XCTAssertEqual(blocks[0].text, "总体情况")
        XCTAssertEqual(String(AnalysisReportPresentation.attributedText(blocks[1].text).characters), "本学期表现 稳定。")
        XCTAssertEqual(String(AnalysisReportPresentation.attributedText(blocks[3].text).characters), "优势：课程完成度高")
    }

    func testMarkdownParserFailureFallsBackToOriginalText() {
        enum ParsingFailure: Error { case expected }
        let source = "**保留原文**"
        let rendered = AnalysisReportPresentation.attributedText(source) { _ in throw ParsingFailure.expected }
        XCTAssertEqual(String(rendered.characters), source)
    }

    func testDisplayTimeRemovesFractionWithoutChangingOriginalTimezoneMeaning() {
        XCTAssertEqual(AnalysisReportPresentation.displayTime("2026-11-11T10:20:30.123456"),
                       "2026-11-11 10:20:30")
        XCTAssertEqual(AnalysisReportPresentation.displayTime("2026-11-11T10:20:30.12+08:00"),
                       "2026-11-11 10:20:30+08:00")
        XCTAssertEqual(AnalysisReportPresentation.displayTime("2026-11-11T10:20:30Z"),
                       "2026-11-11 10:20:30Z")
    }

    func testRouteOriginIsExplicitAndDoesNotDependOnCachedFlag() {
        XCTAssertEqual(AnalysisReportRoute.Origin.freshGeneration.displayName, "实时生成")
        XCTAssertEqual(AnalysisReportRoute.Origin.snapshotCache.displayName, "成绩快照缓存")
        XCTAssertEqual(AnalysisReportRoute.Origin.history.displayName, "历史记录")
    }

    func testLongAndMalformedContentIsRetainedInBlocks() {
        let source = "## 标题\n**未闭合\n\n" + String(repeating: "长文本内容", count: 500)
        let joined = AnalysisReportPresentation.blocks(from: source)
            .filter { $0.kind != .spacer && $0.kind != .heading }
            .map(\.text)
            .joined(separator: "\n")
        XCTAssertTrue(joined.contains("**未闭合"))
        XCTAssertTrue(joined.contains(String(repeating: "长文本内容", count: 500)))
    }
}
