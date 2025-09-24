import SwiftUI
import PhotosUI

struct ContentView: View {
    @State private var showingCamera = false
    @State private var pickedImage: UIImage?
    @State private var recognizedLines: [String] = []
    @State private var positionedLines: [OCRLine] = []   // добавлено
    @State private var parsedItems: [ScheduleItem] = []
    @State private var isRecognizing = false
    @State private var isParsing = false
    @State private var errorMessage: String?
    
    // Import options
    @AppStorage("campusAddress") private var campusAddress: String = ""
    @AppStorage("defaultTransport") private var defaultTransportRaw: String = TransportMode.walking.rawValue
    @AppStorage("semesterEndISO8601") private var semesterEndISO8601: String = ""
    @AppStorage("defaultSubgroup") private var defaultSubgroupRaw: String = Subgroup.ask.rawValue
    
    @State private var scheduleKind: ScheduleKind = .singleDay
    @State private var weekParity: WeekParity = .none
    @State private var subgroup: Subgroup = .ask
    @State private var singleDayDate: Date = DateParsing.nextWorkingDay(from: Date.now)
    @State private var mondayOfWeek: Date = DateParsing.nextMonday(from: Date.now)
    @State private var semesterEndDate: Date? = nil
    @State private var transportMode: TransportMode = .walking
    
    @State private var showingAddressPrompt = false
    @State private var showingSemesterEndPrompt = false
    @State private var showingImportResult = false
    @State private var importResultMessage: String = ""
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Источник")) {
                    HStack {
                        Button {
                            showingCamera = true
                        } label: {
                            Label("Сделать фото", systemImage: "camera")
                        }
                        Spacer()
                        PhotoPickerView(image: $pickedImage)
                    }
                    if let image = pickedImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    if isRecognizing {
                        ProgressView("Распознаём текст…")
                    } else if !recognizedLines.isEmpty {
                        Button {
                            Task { await parseNow() }
                        } label: {
                            Label("Повторить парсинг", systemImage: "arrow.clockwise")
                        }
                    }
                }
                
                if !recognizedLines.isEmpty {
                    Section(header: Text("Распознанный текст")) {
                        ScrollView {
                            Text(recognizedLines.joined(separator: "\n"))
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 150)
                    }
                }
                
                Section(header: Text("Параметры импорта")) {
                    Picker("Тип расписания", selection: $scheduleKind) {
                        Text("Один день").tag(ScheduleKind.singleDay)
                        Text("Недельное").tag(ScheduleKind.weekly)
                    }
                    Picker("Неделя", selection: $weekParity) {
                        Text("Обычная").tag(WeekParity.none)
                        Text("Чётная").tag(WeekParity.even)
                        Text("Нечётная").tag(WeekParity.odd)
                    }
                    Picker("Подгруппа", selection: $subgroup) {
                        Text("Спросить").tag(Subgroup.ask)
                        Text("1").tag(Subgroup.one)
                        Text("2").tag(Subgroup.two)
                        Text("Обе").tag(Subgroup.both)
                    }
                    if scheduleKind == .singleDay {
                        DatePicker("Дата", selection: $singleDayDate, displayedComponents: .date)
                    } else {
                        DatePicker("Понедельник недели", selection: $mondayOfWeek, displayedComponents: .date)
                    }
                    Toggle(isOn: Binding(
                        get: { semesterEndDate != nil },
                        set: { newValue in
                            if newValue && semesterEndDate == nil {
                                showingSemesterEndPrompt = true
                            } else if !newValue {
                                semesterEndDate = nil
                                semesterEndISO8601 = ""
                            }
                        })
                    ) {
                        Text("До конца семестра")
                    }
                    Picker("Транспорт", selection: $transportMode) {
                        Text("Пешком").tag(TransportMode.walking)
                        Text("Общественный").tag(TransportMode.transit)
                    }
                    HStack {
                        Text("Адрес кампуса")
                        Spacer()
                        Text(campusAddress.isEmpty ? "Не указан" : campusAddress)
                            .foregroundStyle(campusAddress.isEmpty ? .secondary : .primary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { showingAddressPrompt = true }
                }
                
                if isParsing {
                    Section { ProgressView("Разбираем расписание…") }
                } else if !parsedItems.isEmpty {
                    Section(header: Text("Найденные пары (\(parsedItems.count))")) {
                        List {
                            ForEach(parsedItems.indices, id: \.self) { idx in
                                let item = parsedItems[idx]
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title)
                                        .font(.headline)
                                    Text("\(DateParsing.hhmm(item.start))–\(DateParsing.hhmm(item.end))")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    HStack {
                                        if let wd = item.weekday {
                                            Text(DateParsing.weekdayName(wd))
                                        }
                                        if let room = item.room, !room.isEmpty {
                                            Text("Ауд.: \(room)")
                                        }
                                        if let teacher = item.teacher, !teacher.isEmpty {
                                            Text(teacher)
                                        }
                                    }
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                }
                            }
                        }
                        Button {
                            Task { await importNow() }
                        } label: {
                            Label("Добавить в календарь", systemImage: "calendar.badge.plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(parsedItems.isEmpty)
                    }
                }
                
                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Фото → Календарь")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await recognizeNow() }
                    } label: {
                        Label("Распознать", systemImage: "text.viewfinder")
                    }
                    .disabled(pickedImage == nil)
                }
            }
            .sheet(isPresented: $showingCamera) {
                CameraView(image: $pickedImage)
            }
            .onChange(of: pickedImage) { _, _ in
                recognizedLines = []
                positionedLines = []
                parsedItems = []
            }
            .alert("Адрес кампуса", isPresented: $showingAddressPrompt) {
                TextField("Город, улица, дом", text: $campusAddress)
                Button("Сохранить") { }
                Button("Отмена", role: .cancel) { }
            } message: {
                Text("Адрес нужен для напоминаний «Пора выходить».")
            }
            .alert("Дата конца семестра", isPresented: $showingSemesterEndPrompt) {
                DatePicker("", selection: Binding(get: {
                    semesterEndDate ?? DateParsing.addWeeks(16, to: mondayOfWeek)
                }, set: { newVal in
                    semesterEndDate = newVal
                    semesterEndISO8601 = ISO8601DateFormatter().string(from: newVal)
                }), displayedComponents: .date)
                .datePickerStyle(.graphical)
                Button("Готово") { }
                Button("Очистить", role: .destructive) {
                    semesterEndDate = nil
                    semesterEndISO8601 = ""
                }
                Button("Отмена", role: .cancel) { }
            } message: {
                Text("Если не указать, можно будет настроить позже.")
            }
            .alert("Готово", isPresented: $showingImportResult) {
                Button("ОК") { }
            } message: {
                Text(importResultMessage)
            }
            .onAppear {
                transportMode = TransportMode(rawValue: defaultTransportRaw) ?? .walking
                subgroup = Subgroup(rawValue: defaultSubgroupRaw) ?? .ask
                if let date = ISO8601DateFormatter().date(from: semesterEndISO8601) {
                    semesterEndDate = date
                }
            }
            .onChange(of: transportMode) { _, newVal in
                defaultTransportRaw = newVal.rawValue
            }
            .onChange(of: subgroup) { _, newVal in
                defaultSubgroupRaw = newVal.rawValue
            }
        }
    }
    
    private func recognizeNow() async {
        guard let image = pickedImage else { return }
        errorMessage = nil
        isRecognizing = true
        defer { isRecognizing = false }
        do {
            let positioned = try await TextRecognitionService.shared.recognizePositionedLines(in: image, languages: ["ru", "en", "de"])
            self.positionedLines = positioned
            self.recognizedLines = positioned.map { $0.text }
            await parseNow()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    private func parseNow() async {
        isParsing = true
        defer { isParsing = false }
        if !positionedLines.isEmpty {
            parsedItems = ScheduleParser.parsePositioned(lines: positionedLines)
        } else {
            parsedItems = ScheduleParser.parse(lines: recognizedLines)
        }
    }
    
    private func importNow() async {
        errorMessage = nil
        do {
            let startAnchor: Date
            let endRepeat: Date?
            switch scheduleKind {
            case .singleDay:
                startAnchor = Calendar.current.startOfDay(for: singleDayDate)
            case .weekly:
                startAnchor = Calendar.current.startOfDay(for: mondayOfWeek)
            }
            endRepeat = semesterEndDate ?? (semesterEndISO8601.isEmpty ? nil : ISO8601DateFormatter().date(from: semesterEndISO8601))
            
            let result = try await CalendarService.shared.importSchedule(items: parsedItems,
                                                                         scheduleKind: scheduleKind,
                                                                         weekParity: weekParity,
                                                                         subgroup: subgroup,
                                                                         startAnchor: startAnchor,
                                                                         repeatUntil: endRepeat,
                                                                         campusAddress: campusAddress,
                                                                         transport: transportMode)
            importResultMessage = "Добавлено событий: \(result.addedCount)\nПропущено: \(result.skippedCount)"
            showingImportResult = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    ContentView()
}
