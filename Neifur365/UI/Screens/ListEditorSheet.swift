import SwiftUI

struct ListEditorSheet: View {
    @EnvironmentObject private var app: AppContainer
    @Environment(\.dismiss) private var dismiss

    let seriesId: Int64
    let title: String
    let series: Series?
    let maxEpisodes: Int?

    @State private var status: ListStatus
    @State private var watched: Int
    @State private var score: Int
    @State private var isInList: Bool
    @State private var saving = false
    @State private var errorMessage: String?

    init(
        seriesId: Int64,
        title: String,
        series: Series? = nil,
        current: ListedTitle?
    ) {
        self.seriesId = seriesId
        self.title = title
        self.series = series ?? current?.series
        self.maxEpisodes = current?.total ?? series.flatMap { $0.numberOfEpisodes > 0 ? $0.numberOfEpisodes : nil }
        _status = State(initialValue: current?.status ?? .watching)
        _watched = State(initialValue: current?.entry.watched ?? 0)
        _score = State(initialValue: current?.entry.score ?? 0)
        _isInList = State(initialValue: current?.status != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Статус") {
                    Picker("Список", selection: $status) {
                        ForEach(ListStatus.allCases) { st in
                            Label(st.title, systemImage: st.systemImage).tag(st)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section("Прогресс") {
                    Stepper(value: $watched, in: 0...(maxEpisodes ?? 9999)) {
                        HStack {
                            Text("Просмотрено серий")
                            Spacer()
                            Text(maxEpisodes.map { "\(watched) / \($0)" } ?? "\(watched)")
                                .foregroundColor(Nf.textDim)
                                .monospacedDigit()
                        }
                    }
                }

                Section("Оценка") {
                    Picker("Оценка", selection: $score) {
                        Text("Без оценки").tag(0)
                        ForEach((1...10).reversed(), id: \.self) { val in
                            Text("\(val) — \(scoreLabel(val))").tag(val)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(Nf.red)
                    }
                }

                if isInList {
                    Section {
                        Button(role: .destructive) {
                            save(remove: true)
                        } label: {
                            HStack {
                                Spacer()
                                Text("Убрать из списка")
                                Spacer()
                            }
                        }
                        .disabled(saving)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Сохранить") { save(remove: false) }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save(remove: Bool) {
        saving = true
        errorMessage = nil
        Task {
            let result = await app.lists.set(
                seriesId: seriesId,
                status: remove ? nil : status,
                watched: remove ? 0 : watched,
                score: remove ? nil : (score > 0 ? score : nil),
                series: series,
                title: title
            )
            saving = false
            switch result {
            case .success:
                dismiss()
            case .failure(let err):
                errorMessage = err.userMessage
            }
        }
    }
}
