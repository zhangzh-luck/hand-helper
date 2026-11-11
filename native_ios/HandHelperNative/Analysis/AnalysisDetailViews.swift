import SwiftUI

@MainActor
struct GradeDetailView: View {
    let grade: GradeRecord
    let focusTitle: Bool
    let onClose: () -> Void
    var glassHeader = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 4, height: 26)
                    .accessibilityHidden(true)
                Text(grade.courseName)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityFocused($titleFocused)
                Spacer(minLength: 0)
                GlassCloseButton(accessibilityLabel: "关闭成绩详情", diameter: 44,
                                 onDarkBackground: false, action: onClose)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 14) {
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 10) { scores }
                    } else {
                        HStack(alignment: .top, spacing: 8) { scores }
                    }
                }
                .padding(12)
                .background(Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 12) {
                    detail("学分 / 绩点", "\(grade.credits.map { String($0) } ?? "—") / \(grade.gradePoint.map { String($0) } ?? "—")", symbol: "graduationcap")
                    detail("课程性质", grade.courseType ?? "未提供", symbol: "books.vertical")
                    detail("考试性质", grade.examType ?? "未提供", symbol: "doc.text")
                    detail("补考 / 重修", "\(grade.makeupFlag ? "补考" : "否") / \(grade.retakeFlag ? "重修" : "否")", symbol: "arrow.clockwise")
                    if !grade.courseCode.isEmpty {
                        detail("课程代码", grade.courseCode, symbol: "number", secondary: true)
                    }
                    if let weighted = grade.weightedGradePoint {
                        detail("加权绩点", String(weighted), symbol: "chart.bar", secondary: true)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, glassHeader ? 14 : 0)
            .padding(.bottom, 20)
            .background {
                if glassHeader {
                    Color(uiColor: .systemGroupedBackground).opacity(0.94)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .onChange(of: focusTitle) { _, value in titleFocused = value }
    }

    @ViewBuilder
    private var scores: some View {
        score("总评成绩", grade.score ?? "未公布", emphasized: true)
        score("期末成绩", grade.finalExamScore ?? "未提供")
        score("平时成绩", grade.usualScore ?? "未提供")
    }

    private func score(_ title: String, _ value: String, emphasized: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(emphasized ? .title3.weight(.bold) : .body.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func detail(_ label: String, _ value: String, symbol: String,
                        secondary: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value).foregroundStyle(secondary ? Color.secondary : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}

struct AnalysisReportRoute: Identifiable {
    enum Origin: Equatable {
        case freshGeneration
        case snapshotCache
        case history

        var displayName: String {
            switch self {
            case .freshGeneration: "实时生成"
            case .snapshotCache: "成绩快照缓存"
            case .history: "历史记录"
            }
        }

        var systemImage: String {
            switch self {
            case .freshGeneration: "sparkles"
            case .snapshotCache: "tray.full"
            case .history: "clock.arrow.circlepath"
            }
        }
    }

    let id = UUID()
    let analysis: GradeAIAnalysis
    let origin: Origin
}

struct AnalysisReportBlock: Identifiable, Equatable {
    enum Kind: Equatable {
        case heading
        case paragraph
        case bullet
        case spacer
    }

    let id: Int
    let kind: Kind
    let text: String
}

struct AnalysisReportRenderedBlock: Identifiable {
    let id: Int
    let kind: AnalysisReportBlock.Kind
    let text: AttributedString
}

enum AnalysisReportPresentation {
    static func blocks(from content: String) -> [AnalysisReportBlock] {
        var blocks: [AnalysisReportBlock] = []
        var paragraphLines: [String] = []

        func append(_ kind: AnalysisReportBlock.Kind, _ text: String = "") {
            blocks.append(AnalysisReportBlock(id: blocks.count, kind: kind, text: text))
        }

        func finishParagraph() {
            guard !paragraphLines.isEmpty else { return }
            append(.paragraph, paragraphLines.joined(separator: "\n"))
            paragraphLines.removeAll(keepingCapacity: true)
        }

        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                finishParagraph()
                if !blocks.isEmpty, blocks.last?.kind != .spacer { append(.spacer) }
            } else if trimmed.hasPrefix("## ") {
                finishParagraph()
                append(.heading, String(trimmed.dropFirst(3)))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                finishParagraph()
                append(.bullet, String(trimmed.dropFirst(2)))
            } else {
                paragraphLines.append(line)
            }
        }
        finishParagraph()
        if blocks.last?.kind == .spacer { blocks.removeLast() }
        return blocks
    }

    static func attributedText(_ text: String) -> AttributedString {
        attributedText(text) { value in
            try AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        }
    }

    static func attributedText(
        _ text: String,
        parser: (String) throws -> AttributedString
    ) -> AttributedString {
        (try? parser(text)) ?? AttributedString(text)
    }

    static func renderedBlocks(from content: String) -> [AnalysisReportRenderedBlock] {
        blocks(from: content).map { block in
            AnalysisReportRenderedBlock(
                id: block.id,
                kind: block.kind,
                text: block.kind == .spacer ? AttributedString("") : attributedText(block.text)
            )
        }
    }

    static func displayTime(_ rawValue: String) -> String {
        let normalized = rawValue.replacingOccurrences(of: "T", with: " ")
        guard let fractionalStart = normalized.firstIndex(of: ".") else { return normalized }
        var fractionalEnd = normalized.index(after: fractionalStart)
        while fractionalEnd < normalized.endIndex, normalized[fractionalEnd].isNumber {
            fractionalEnd = normalized.index(after: fractionalEnd)
        }
        return String(normalized[..<fractionalStart]) + String(normalized[fractionalEnd...])
    }
}

@MainActor
struct GradeAIReportView: View {
    let analysis: GradeAIAnalysis
    let origin: AnalysisReportRoute.Origin
    let onRegenerate: () -> Void
    private let reportBlocks: [AnalysisReportRenderedBlock]
    private let displayTime: String

    init(
        analysis: GradeAIAnalysis,
        origin: AnalysisReportRoute.Origin,
        onRegenerate: @escaping () -> Void
    ) {
        self.analysis = analysis
        self.origin = origin
        self.onRegenerate = onRegenerate
        reportBlocks = AnalysisReportPresentation.renderedBlocks(from: analysis.content)
        displayTime = AnalysisReportPresentation.displayTime(analysis.createdAt)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    metadataCard
                    Button(action: onRegenerate) {
                        Label("重新生成", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHint("基于当前成绩重新发起 AI 分析")
                    Divider()
                    reportContent
                }
                .padding(20)
            }
            .navigationTitle("分析结果")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var metadataCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("AI 成绩分析", systemImage: "sparkles")
                .font(.headline)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    metadataItem("模型", value: analysis.model)
                    metadataItem("服务提供方", value: analysis.provider)
                }
                VStack(alignment: .leading, spacing: 10) {
                    metadataItem("模型", value: analysis.model)
                    metadataItem("服务提供方", value: analysis.provider)
                }
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Label(origin.displayName, systemImage: origin.systemImage)
                    Spacer(minLength: 8)
                    Text(displayTime).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Label(origin.displayName, systemImage: origin.systemImage)
                    Label(displayTime, systemImage: "calendar")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.footnote)
        }
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func metadataItem(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.footnote).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.medium)).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var reportContent: some View {
        ForEach(reportBlocks) { block in
            switch block.kind {
            case .heading:
                Text(block.text)
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
            case .paragraph:
                Text(block.text)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            case .bullet:
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                        .foregroundStyle(.secondary)
                    Text(block.text)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .spacer:
                Color.clear.frame(height: 4).accessibilityHidden(true)
            }
        }
    }
}
