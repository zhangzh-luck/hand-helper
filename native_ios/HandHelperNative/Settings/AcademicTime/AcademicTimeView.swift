import SwiftUI

@MainActor
struct AcademicTimeView: View {
    @ObservedObject private var state: AppState
    @StateObject private var model: AcademicTimeViewModel

    init(state: AppState) {
        self.state = state
        _model = StateObject(wrappedValue: AcademicTimeViewModel(
            state: state, service: AcademicTimeService(api: state.api)))
    }

    var body: some View {
        List {
            if let error = model.errorMessage {
                Section {
                    Text(error).foregroundStyle(.red)
                    if model.terms.isEmpty || model.periods.isEmpty {
                        Button("重试读取") { Task { await model.load() } }
                            .disabled(model.isSaving || model.isLoading)
                    }
                }
            }
            if model.hasFinishedLoading && !model.isLoading && model.errorMessage == nil &&
                (model.terms.isEmpty || model.periods.isEmpty) {
                Section {
                    Text(model.terms.isEmpty ? "尚无学期数据，请先导入打印课表文件。" : "节次时间暂不可用。")
                        .foregroundStyle(.secondary)
                    Button("重试读取") { Task { await model.load() } }
                        .disabled(model.isSaving || model.isLoading)
                }
            }
            if let status = model.statusMessage {
                Section { Text(status).foregroundStyle(.secondary) }
            }

            Section {
                if model.selectedTerm != nil && !model.isLoading {
                    Picker("学期", selection: Binding(
                        get: { model.selectedTermID },
                        set: { model.selectTerm($0) }
                    )) {
                        ForEach(model.terms, id: \.id) { term in
                            Text(term.displayName).tag(Optional(term.id))
                        }
                    }
                    .disabled(model.isSaving || model.isLoading)
                } else {
                    placeholderRow("学期", value: termPlaceholder)
                }
                if model.hasValidTermDate && !model.isLoading {
                    DatePicker("第一周周一", selection: $model.firstMonday, displayedComponents: .date)
                        .disabled(model.isSaving || model.isLoading)
                } else {
                    placeholderRow("第一周周一", value: model.selectedTerm != nil && !model.isLoading ? "日期无效" : termPlaceholder)
                }
                if model.termIsDirty {
                        HStack {
                            Button("取消") { model.selectTerm(model.selectedTermID) }
                            Spacer()
                            Button("保存第一周") { Task { await model.saveTerm() } }
                                .buttonStyle(.borderedProminent)
                        }
                        .disabled(model.isSaving || model.isLoading)
                }
            } header: {
                Text("学期第一周")
            } footer: {
                Text("第一周必须从星期一开始。保存后服务器会重新生成课程日程。")
            }

            Section {
                if model.selectedPeriod != nil && !model.isLoading {
                    Picker("节次", selection: Binding(
                        get: { model.selectedPeriodNumber },
                        set: { model.selectPeriod($0) }
                    )) {
                        ForEach(model.periods, id: \.periodNumber) { period in
                            Text("第 \(period.periodNumber) 节").tag(Optional(period.periodNumber))
                        }
                    }
                    .disabled(model.isSaving || model.isLoading)
                } else {
                    placeholderRow("节次", value: periodPlaceholder)
                }
                if model.hasValidPeriodTimes && !model.isLoading {
                    DatePicker("上课时间", selection: $model.startTime, displayedComponents: .hourAndMinute)
                        .disabled(model.isSaving || model.isLoading)
                    DatePicker("下课时间", selection: $model.endTime, displayedComponents: .hourAndMinute)
                        .disabled(model.isSaving || model.isLoading)
                } else {
                    let value = model.selectedPeriod != nil && !model.isLoading ? "时间无效" : periodPlaceholder
                    placeholderRow("上课时间", value: value)
                    placeholderRow("下课时间", value: value)
                }
                if model.periodIsDirty {
                        HStack {
                            Button("取消") { model.selectPeriod(model.selectedPeriodNumber) }
                            Spacer()
                            Button("保存节次") { Task { await model.savePeriod() } }
                                .buttonStyle(.borderedProminent)
                        }
                        .disabled(model.isSaving || model.isLoading)
                }
            } header: {
                Text("节次时间")
            } footer: {
                Text("下课时间必须晚于上课时间。保存后服务器会重新生成课程日程。")
            }
            if !state.visiblePendingAcademicTimeWrites.isEmpty {
                Section {
                    ForEach(state.visiblePendingAcademicTimeWrites) { pending in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(pending.target.title).font(.headline)
                            Text(pending.message ?? "服务端已接受写入，等待读回确认。")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Button("重新核对") {
                                Task {
                                    await state.reconcilePendingAcademicTimeWrites()
                                    await model.load()
                                }
                            }
                            .disabled(model.isSaving || model.isLoading)
                        }
                    }
                } header: {
                    Text("待核实的写入")
                } footer: {
                    Text("重新核对只读取服务端当前值，不会再次提交修改。")
                }
            }
            if model.isSaving {
                Section { ProgressView("正在保存并读取服务端结果") }
            }
        }
        .navigationTitle("时间设置")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .onChange(of: state.authenticationRevision) { _, _ in
            model.reset()
            if state.canAccessPrivateData { Task { await model.load() } }
        }
    }

    private var termPlaceholder: String {
        if model.isLoading || !model.hasFinishedLoading { return "正在读取" }
        return model.errorMessage == nil ? "尚无学期数据" : "读取失败"
    }

    private var periodPlaceholder: String {
        if model.isLoading || !model.hasFinishedLoading { return "正在读取" }
        return model.errorMessage == nil ? "节次不可用" : "读取失败"
    }

    private func placeholderRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
