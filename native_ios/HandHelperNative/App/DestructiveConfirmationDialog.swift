import SwiftUI

enum DestructiveConfirmationKind: Equatable {
    case grades, schedule, manualCourse

    var title: String {
        switch self {
        case .grades: "删除本学期成绩？"
        case .schedule: "删除这项安排？"
        case .manualCourse: "删除这门课程？"
        }
    }

    var message: String {
        switch self {
        case .grades: "将删除本学期已导入的全部成绩及对应 AI 分析缓存，此操作无法撤销，其他学期不受影响。"
        case .schedule: "删除后无法恢复这项自定义安排。"
        case .manualCourse: "删除后这门手动课程将从本机课程表移除。"
        }
    }

    var deleteTitle: String {
        switch self {
        case .grades: "删除成绩"
        case .schedule: "删除安排"
        case .manualCourse: "删除课程"
        }
    }
}

struct DestructiveConfirmationRequest: Identifiable {
    let id = UUID()
    let kind: DestructiveConfirmationKind
    let confirm: @MainActor () -> Void
    let cancel: @MainActor () -> Void
}

enum DestructiveConfirmationPhase: Equatable {
    case idle, presented, closingConfirm, closingCancel
}

@MainActor
final class DestructiveConfirmationCoordinator: ObservableObject {
    @Published private(set) var request: DestructiveConfirmationRequest?
    @Published private(set) var phase: DestructiveConfirmationPhase = .idle
    @Published private(set) var visible = false

    var isPresenting: Bool { request != nil }
    var isExecuting: Bool { phase == .closingConfirm }

    @discardableResult
    func present(_ kind: DestructiveConfirmationKind,
                 confirm: @escaping @MainActor () -> Void,
                 cancel: @escaping @MainActor () -> Void) -> Bool {
        guard request == nil, phase == .idle else { return false }
        request = DestructiveConfirmationRequest(kind: kind, confirm: confirm, cancel: cancel)
        phase = .presented
        visible = true
        return true
    }

    @discardableResult
    func beginClose(id: UUID, confirmed: Bool) -> Bool {
        guard request?.id == id, phase == .presented else { return false }
        phase = confirmed ? .closingConfirm : .closingCancel
        return true
    }

    func hide(id: UUID) {
        guard request?.id == id, phase == .closingConfirm || phase == .closingCancel else { return }
        visible = false
    }

    func finish(id: UUID) {
        guard let current = request, current.id == id,
              phase == .closingConfirm || phase == .closingCancel else { return }
        let confirmed = phase == .closingConfirm
        request = nil
        phase = .idle
        visible = false
        if confirmed { current.confirm() }
        else { current.cancel() }
    }

    func clear() {
        guard let current = request else { return }
        request = nil
        phase = .idle
        visible = false
        current.cancel()
    }
}

enum DestructiveConfirmationSurface: Equatable {
    case glass, material, opaque

    static func current(supportsGlass: Bool, reduceTransparency: Bool,
                        increasedContrast: Bool) -> Self {
        if reduceTransparency || increasedContrast { return .opaque }
        return supportsGlass ? .glass : .material
    }
}

struct DestructiveConfirmationDialog: View {
    @ObservedObject var confirmation: DestructiveConfirmationCoordinator

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AccessibilityFocusState private var titleFocused: Bool

    private var surface: DestructiveConfirmationSurface {
        let supportsGlass: Bool
        if #available(iOS 26.0, *) { supportsGlass = true }
        else { supportsGlass = false }
        return .current(supportsGlass: supportsGlass,
                        reduceTransparency: reduceTransparency,
                        increasedContrast: contrast == .increased)
    }

    private var motion: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.28, bounce: 0.03)
    }

    private var transition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.94).combined(with: .opacity)
    }

    var body: some View {
        GeometryReader { geometry in
            if let request = confirmation.request, confirmation.visible {
                ZStack {
                    Color.black.opacity(colorScheme == .dark ? 0.46 : 0.35)
                        .ignoresSafeArea()
                        .accessibilityHidden(true)

                    ViewThatFits(in: .vertical) {
                        content(for: request)
                            .fixedSize(horizontal: false, vertical: true)
                        ScrollView {
                            content(for: request)
                        }
                        .scrollBounceBehavior(.basedOnSize)
                    }
                    .frame(width: min(360, max(0, geometry.size.width - 32)))
                    .frame(maxHeight: max(0, geometry.size.height - 32))
                    .modifier(ConfirmationSurface(kind: surface))
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 22, y: 10)
                    .transition(transition)
                    .accessibilityElement(children: .contain)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .onAppear { titleFocused = true }
                .onChange(of: request.id) { _, _ in titleFocused = true }
            }
        }
        .allowsHitTesting(confirmation.isPresenting)
        .animation(motion, value: confirmation.visible)
    }

    private func content(for request: DestructiveConfirmationRequest) -> some View {
        VStack(spacing: 12) {
            Text(request.kind.title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .accessibilityFocused($titleFocused)
            Text(request.kind.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)
            VStack(spacing: 8) {
                deleteButton(for: request)
                cancelButton(for: request)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func deleteButton(for request: DestructiveConfirmationRequest) -> some View {
        let button = Button(role: .destructive) {
            close(request, confirmed: true)
        } label: {
            Text(request.kind.deleteTitle)
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .tint(.red)
        .disabled(confirmation.isExecuting)
        if #available(iOS 26.0, *), surface == .glass {
            button.buttonStyle(.glassProminent)
        } else {
            button.buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private func cancelButton(for request: DestructiveConfirmationRequest) -> some View {
        let button = Button("取消") { close(request, confirmed: false) }
            .font(.body.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 44)
            .disabled(confirmation.isExecuting)
        if #available(iOS 26.0, *), surface == .glass {
            button.buttonStyle(.glass)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private func close(_ request: DestructiveConfirmationRequest, confirmed: Bool) {
        guard confirmation.beginClose(id: request.id, confirmed: confirmed) else { return }
        withAnimation(motion, completionCriteria: .removed) {
            confirmation.hide(id: request.id)
        } completion: {
            confirmation.finish(id: request.id)
        }
    }
}

private struct ConfirmationSurface: ViewModifier {
    let kind: DestructiveConfirmationSurface

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        switch kind {
        case .glass:
            if #available(iOS 26.0, *) {
                content.glassEffect(.regular, in: shape)
            }
        case .material:
            content.background(.thickMaterial, in: shape)
        case .opaque:
            content.background(Color(uiColor: .systemBackground), in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.5))
        }
    }
}
