import SwiftUI
import PhotosUI

struct ContentView: View {
    @State private var pickedImage: UIImage?
    @State private var recognizedLines: [String] = []
    @State private var positionedLines: [OCRLine] = []
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
    
    // Camera sheet state
    @State private var showingCamera = false
    
    // Photo picker local state
    @State private var photoSelection: PhotosPickerItem?
    @State private var isPhotoLoading = false
    @State private var showPhotoError = false
    @State private var photoErrorMessage: String?
    
    // Shared formatter to avoid constructing inside closures
    private static let isoFormatter = ISO8601DateFormatter()
    
    // Extracted bindings to simplify type-checking
    private var semesterEndEnabledBinding: Binding<Bool> {
        Binding(
            get: { semesterEndDate != nil },
            set: { newValue in
                if newValue && semesterEndDate == nil {
                    showingSemesterEndPrompt = true
                } else if !newValue {
                    semesterEndDate = nil
                    semesterEndISO8601 = ""
                }
            }
        )
    }
    
    private var semesterEndPickerBinding: Binding<Date> {
        Binding(
            get: { semesterEndDate ?? DateParsing.addWeeks(16, to: mondayOfWeek) },
            set: { newDate in
                updateSemesterEndDate(newDate)
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                sourceSection()
                
                if !recognizedLines.isEmpty {
                    recognizedTextSection()
                }
                
                importParamsSection()
                
                if isParsing {
                    Section { ProgressView("Разбираем расписание…") }
                } else if !parsedItems.isEmpty {
                    parsedItemsSection()
                }
                
                if let errorMessage {
                    errorSection(message: errorMessage)
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
            .sheet(isPresented: $showingCamera, onDismiss: {
                // дополнительная страховка синхронизации
                showingCamera = false
            }) {
                CameraView(image: $pickedImage, isPresented: $showingCamera)
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
                DatePicker("", selection: semesterEndPickerBinding, displayedComponents: .date)
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
            // Обработка выбора фото
            .onChange(of: photoSelection) { _, newItem in
                guard let item = newItem else { return }
                Task { await loadPhoto(from: item) }
            }
            .alert("Ошибка загрузки фото", isPresented: $showPhotoError) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(photoErrorMessage ?? "Неизвестная ошибка")
            }
            .onAppear {
                transportMode = TransportMode(rawValue: defaultTransportRaw) ?? .walking
                subgroup = Subgroup(rawValue: defaultSubgroupRaw) ?? .ask
                if let date = ContentView.isoFormatter.date(from: semesterEndISO8601) {
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
    
    // MARK: - Sections split into helpers
    
    @ViewBuilder
    private func sourceSection() -> some View {
        Section(header: Text("Источник")) {
            // Разнос по разным строкам снижает шанс хит-тест конфликтов
            Button {
                showingCamera = true
            } label: {
                Label("Сделать фото", systemImage: "camera")
            }
            .disabled(isPhotoLoading) // PhotosPicker сам отключится, когда showingCamera == true
            
            HStack {
                PhotosPicker(selection: $photoSelection, matching: .images) {
                    photosPickerLabel()
                }
                .disabled(isPhotoLoading || showingCamera)
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
    }
    
    @ViewBuilder
    private func photosPickerLabel() -> some View {
        if isPhotoLoading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Загружаем…")
            }
        } else {
            Label("Выбрать фото", systemImage: "photo.on.rectangle")
        }
    }
    
    @ViewBuilder
    private func recognizedTextSection() -> some View {
        Section(header: Text("Распознанный текст")) {
            ScrollView {
                Text(recognizedLines.joined(separator: "\n"))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
        }
    }
    
    @ViewBuilder
    private func importParamsSection() -> some View {
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
            Toggle(isOn: semesterEndEnabledBinding) {
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
    }
    
    @ViewBuilder
    private func parsedItemsSection() -> some View {
        Section(header: Text("Найденные пары (\(parsedItems.count))")) {
            ForEach(parsedItems) { item in
                parsedItemRow(item)
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
    
    @ViewBuilder
    private func parsedItemRow(_ item: ScheduleItem) -> some View {
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
    
    @ViewBuilder
    private func errorSection(message: String) -> some View {
        Section {
            Text(message).foregroundStyle(.red)
        }
    }
    
    // MARK: - Logic
    
    private func updateSemesterEndDate(_ newVal: Date) {
        semesterEndDate = newVal
        semesterEndISO8601 = ContentView.isoFormatter.string(from: newVal)
    }
    
    private func loadPhoto(from item: PhotosPickerItem) async {
        isPhotoLoading = true
        defer { isPhotoLoading = false }
        do {
            if let data = try await item.loadTransferable(type: Data.self),
               let uiImage = UIImage(data: data) {
                pickedImage = uiImage
                photoSelection = nil
                return
            }
            if let url = try? await item.loadTransferable(type: URL.self),
               let data = try? Data(contentsOf: url),
               let uiImage = UIImage(data: data) {
                pickedImage = uiImage
                photoSelection = nil
                return
            }
            throw NSError(domain: "PhotoPicker",
                          code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Не удалось получить изображение"])
        } catch {
            photoErrorMessage = (error as NSError).localizedDescription
            showPhotoError = true
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
            endRepeat = semesterEndDate ?? (semesterEndISO8601.isEmpty ? nil : ContentView.isoFormatter.date(from: semesterEndISO8601))
            
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
