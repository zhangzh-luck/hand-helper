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
            if model.isLoading {
                Section { ProgressView("正在读取时间设置") }
            }
            if let error = model.errorMessage {
                Section {
                    Text(error).foregroundStyle(.red)
                    if model.terms.isEmpty || model.periods.isEmpty {
                        Button("重试读取") { Task { await model.load() } }
                            .disabled(model.isSaving || model.isLoading)
                    }
                }
            }
            if let status = model.statusMessage {
                Section { Text(status).foregroundStyle(.secondary) }
            }

            Section {
                if model.terms.isEmpty {
                    Text("尚无学期数据，请先导入打印课表文件。")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("学期", selection: Binding(
                        get: { model.selectedTermID },
                        set: { model.selectTerm($0) }
                    )) {
                        ForEach(model.terms, id: \.id) { term in
                            Text(term.displayName).tag(Optional(term.id))
                        }
                    }
                    .disabled(model.isSaving || model.isLoading)
                    DatePicker("第一周周一", selection: $model.firstMonday, displayedComponents: .date)
                        .disabled(model.isSaving || model.isLoading)
                    if model.termIsDirty {
                        HStack {
                            Button("取消") { model.selectTerm(model.selectedTermID) }
                            Spacer()
                            Button("保存第一周") { Task { await model.saveTerm() } }
                                .buttonStyle(.borderedProminent)
                        }
                        .disabled(model.isSaving || model.isLoading)
                    }
                }
            } header: {
                Text("学期第一周")
            } footer: {
                Text("第一周必须从星期一开始。保存后服务器会重新生成课程日程。")
            }

            Section {
                if model.periods.isEmpty {
                    Text("节次时间暂不可用。").foregroundStyle(.secondary)
                } else {
                    Picker("节次", selection: Binding(
                        get: { model.selectedPeriodNumber },
                        set: { model.selectPeriod($0) }
                    )) {
                        ForEach(model.periods, id: \.periodNumber) { period in
                            Text("第 \(period.periodNumber) 节").tag(Optional(period.periodNumber))
                        }
                    }
                    .disabled(model.isSaving || model.isLoading)
                    DatePicker("上课时间", selection: $model.startTime, displayedComponents: .hourAndMinute)
                        .disabled(model.isSaving || model.isLoading)
                    DatePicker("下课时间", selection: $model.endTime, displayedComponents: .hourAndMinute)
                        .disabled(model.isSaving || model.isLoading)
                    if model.periodIsDirty {
                        HStack {
                            Button("取消") { model.selectPeriod(model.selectedPeriodNumber) }
                            Spacer()
                            Button("保存节次") { Task { await model.savePeriod() } }
                                .buttonStyle(.borderedProminent)
                        }
                        .disabled(model.isSaving || model.isLoading)
                    }
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
}
