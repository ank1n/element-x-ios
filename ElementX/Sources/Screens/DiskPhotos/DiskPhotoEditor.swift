// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import SwiftUI

struct DiskPhotoEditor: View {
    let photo: DiskPhoto
    let service: DiskPhotoService
    let saved: () -> Void
    /// A custom loader transfers ownership of one app-owned COPY, never the SDK's cached original.
    let loadOriginal: (() async throws -> URL)?
    let verifySourceAccess: (() async -> Bool)?

    init(photo: DiskPhoto, service: DiskPhotoService, saved: @escaping () -> Void,
         loadOriginal: (() async throws -> URL)? = nil, verifySourceAccess: (() async -> Bool)? = nil) {
        self.photo = photo; self.service = service; self.saved = saved
        self.loadOriginal = loadOriginal; self.verifySourceAccess = verifySourceAccess
    }

    @Environment(\.dismiss) private var dismiss
    @State private var source: DiskPhotoEditSource?
    @State private var previewBase: UIImage?
    @State private var preview: UIImage?
    @State private var edits = DiskPhotoEdits()
    @State private var history = DiskPhotoEditHistory()
    @State private var tool = Tool.crop
    @State private var color = Color(red: 1, green: 59 / 255, blue: 48 / 255)
    @State private var textSize = 0.04
    @State private var text = ""
    @State private var textAt: CGPoint?
    @State private var textPrompt = false
    @State private var cropRegion: CGRect?
    @State private var dragStart: CGPoint?
    @State private var dragEnd: CGPoint?
    @State private var movingCrop: CGRect?
    @State private var selected: Int?
    @State private var movingObject: DiskPhotoEditObject?
    @State private var brightness = 0.0
    @State private var contrast = 0.0
    @State private var error: String?
    @State private var folderError: String?
    @State private var saving = false
    @State private var filename = ""
    @State private var format = DiskPhotoEditFormat.png
    // nil is deliberate: a huge original requires an explicit reduced-size choice.
    @State private var resolution: DiskPhotoEditResolution?
    @State private var exportBudget = DiskPhotoEditMemoryBudget.current
    @State private var keepCaptureMetadata = true
    @State private var folders: [DiskFolder] = []
    @State private var folderID: String?
    @State private var discardPrompt = false

    private enum Tool: String, CaseIterable {
        case select = "Выбрать", crop = "Обрезка", arrow = "Стрелка", rectangle = "Рамка", text = "Текст", redact = "Замазка"
        var label: String {
            switch self {
            case .select: NSLocalizedString("Выбрать", comment: "Photo editor tool")
            case .crop: NSLocalizedString("Обрезка", comment: "Photo editor tool")
            case .arrow: NSLocalizedString("Стрелка", comment: "Photo editor tool")
            case .rectangle: NSLocalizedString("Рамка", comment: "Photo editor tool")
            case .text: NSLocalizedString("Текст", comment: "Photo editor tool")
            case .redact: NSLocalizedString("Замазка", comment: "Photo editor tool")
            }
        }
    }

    private var hexColor: String {
        let resolved = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        var r: CGFloat = 1, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    private var effective: DiskPhotoEdits {
        var result = edits
        if brightness != 0 || contrast != 0 { result.operations.append(.adjust(brightness: brightness, contrast: contrast)) }
        return result
    }

    private var previewEdits: DiskPhotoEdits {
        var result = effective
        if let start = dragStart, let end = dragEnd {
            if let object = movingObject, object.index < result.operations.count {
                let delta = object.delta(CGPoint(x: end.x - start.x, y: end.y - start.y))
                result.operations[object.index] = DiskPhotoEditGeometry.moved(result.operations[object.index], by: delta)
            } else if let annotation = annotation(from: start, to: end) { result.operations.append(annotation) }
        }
        return result
    }

    private var dirty: Bool {
        !edits.operations.isEmpty || brightness != 0 || contrast != 0 || cropRegion != nil
    }

    private var canSave: Bool {
        guard let source, let resolution else { return false }
        return exportBudget.allows(source.rasterSize(resolution: resolution)) && !saving && cropRegion == nil && dragStart == nil && !textPrompt
            && (try? format.filename(filename)) != nil
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let error {
                    Text(error).foregroundStyle(.red).font(.footnote).padding(8)
                        .accessibilityLabel(String(format: NSLocalizedString("stalk_photos_edit_error", comment: "Photo editor error, %@"), error))
                }
                if let source {
                    stage(source).frame(minHeight: 180, maxHeight: 340)
                    if cropRegion != nil {
                        HStack {
                            Button("Применить обрезку") { applyCrop() }
                            Button("Снять область") { cropRegion = nil }
                        }.padding(6)
                    }
                    settings(source)
                } else if error == nil { ProgressView("Открываем оригинал…").frame(maxHeight: .infinity) }
            }
            .navigationTitle("Редактор копии")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(saving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.actionCancel) { requestClose() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? NSLocalizedString("Сохранение…", comment: "Photo editor saving") : NSLocalizedString("Сохранить копию", comment: "Save edited photo")) { Task { await save() } }.disabled(!canSave)
                }
            }
            .confirmationDialog("Закрыть без сохранения?", isPresented: $discardPrompt, titleVisibility: .visible) {
                Button("Не сохранять", role: .destructive) { dismiss() }
                Button("Продолжить редактирование", role: .cancel) { }
            }
            .alert("Текст на фото", isPresented: $textPrompt) {
                TextField("Подпись", text: $text)
                Button(L10n.actionCancel, role: .cancel) { textAt = nil }
                Button("Добавить") {
                    if let at = textAt, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        append(.text(at: at, text: String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)), color: hexColor, size: textSize))
                    }
                    textAt = nil
                }
            }
        }
        .interactiveDismissDisabled(dirty || saving)
        .task { await load() }
        .task { await loadFolders() }
        .task(id: previewEdits) { await renderPreview() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            exportBudget = .current
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            exportBudget = .current
        }
        .onDisappear { if let source { DiskPhotoEditSource.cleanupDownload(source.url, appOwnedCopy: loadOriginal != nil) } }
    }

    private func stage(_ source: DiskPhotoEditSource) -> some View {
        GeometryReader { geometry in
            let size = DiskPhotoEditRenderer.size(source.size, operations: effective.operations)
            let ratio = min(geometry.size.width / size.width, geometry.size.height / size.height)
            let display = CGSize(width: size.width * ratio, height: size.height * ratio)
            ZStack {
                Rectangle().fill(.gray.opacity(0.15))
                if let preview { Image(uiImage: preview).resizable().interpolation(.high).frame(width: display.width, height: display.height) }
                if let region = displayedCrop {
                    Rectangle().stroke(.yellow, style: StrokeStyle(lineWidth: 2, dash: [6, 3]))
                        .frame(width: region.width * display.width, height: region.height * display.height)
                        .position(x: region.midX * display.width, y: region.midY * display.height)
                }
                if let selected, let object = DiskPhotoEditGeometry.objects(size: source.size, operations: previewEdits.operations).first(where: { $0.index == selected }) {
                    Rectangle().stroke(.cyan, lineWidth: 2)
                        .frame(width: max(6, object.bounds.width * display.width), height: max(6, object.bounds.height * display.height))
                        .position(x: object.bounds.midX * display.width, y: object.bounds.midY * display.height)
                }
            }
            .frame(width: display.width, height: display.height)
            .clipped().contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in dragChanged(value, display: display, source: source) }
                .onEnded { _ in finishDrag() })
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            .accessibilityLabel(String(format: NSLocalizedString("stalk_photos_edit_canvas", comment: "Photo editor canvas, tool %@"), tool.label))
        }.padding(8)
    }

    private func settings(_ source: DiskPhotoEditSource) -> some View {
        Form {
            Section {
                HStack {
                    Button("Повернуть 90°") { append(.rotate(clockwise: true)) }
                    Menu("Отразить") {
                        Button("По горизонтали") { append(.flip(vertical: false)) }
                        Button("По вертикали") { append(.flip(vertical: true)) }
                    }
                }
                HStack {
                    Button("Отменить") { undo() }.disabled(history.undoItems.isEmpty && brightness == 0 && contrast == 0)
                    Button("Повторить") { redo() }.disabled(history.redoItems.isEmpty || brightness != 0 || contrast != 0)
                    Button("Сбросить") { commitAdjustment(); history.record(edits); edits = DiskPhotoEdits(); clearPending() }.disabled(!dirty)
                }
                Picker("Инструмент", selection: $tool) { ForEach(Tool.allCases, id: \.self) { Text($0.label).tag($0) } }
                    .onChange(of: tool) { _, new in
                        let selection = selected
                        clearPlacement()
                        if new == .select { selected = selection }
                    }
                if tool == .arrow || tool == .rectangle || tool == .text {
                    ColorPicker("Цвет пометки", selection: $color, supportsOpacity: false)
                }
                if tool == .text {
                    Text("Размер текста")
                    Slider(value: $textSize, in: 0.02...0.12, step: 0.005).accessibilityLabel(NSLocalizedString("Размер текста", comment: "Photo editor slider"))
                }
                Text(hint).font(.footnote).foregroundStyle(.secondary)
                Text(String(format: NSLocalizedString("stalk_photos_edit_brightness", comment: "Brightness, %lld"), Int64(brightness)))
                Slider(value: $brightness, in: -100...100, step: 1).accessibilityLabel(NSLocalizedString("Яркость", comment: "Photo editor slider")).disabled(edits.operations.count >= 60)
                Text(String(format: NSLocalizedString("stalk_photos_edit_contrast", comment: "Contrast, %lld"), Int64(contrast)))
                Slider(value: $contrast, in: -100...100, step: 1).accessibilityLabel(NSLocalizedString("Контраст", comment: "Photo editor slider")).disabled(edits.operations.count >= 60)
                Button("Применить свет и цвет") { commitAdjustment() }.disabled(brightness == 0 && contrast == 0)
            }
            Section("Сохранение копии") {
                TextField("Имя копии", text: $filename)
                Picker("Формат", selection: $format) {
                    Text("PNG · сохраняет прозрачность").tag(DiskPhotoEditFormat.png)
                    Text("JPEG · белый фон, качество 92%").tag(DiskPhotoEditFormat.jpeg)
                }
                Picker("Размер копии", selection: $resolution) {
                    Text("Выберите размер").tag(DiskPhotoEditResolution?.none)
                    ForEach(DiskPhotoEditResolution.allCases, id: \.self) { option in
                        Text(option.label).tag(Optional(option))
                            .disabled(!exportBudget.allows(source.rasterSize(resolution: option)))
                    }
                }
                Text(String(format: NSLocalizedString("stalk_photos_edit_original_size", comment: "Original pixel width/height"), Int64(source.size.width), Int64(source.size.height)))
                if let resolution {
                    let output = source.outputSize(effective, resolution: resolution)
                    Text(String(format: NSLocalizedString("stalk_photos_edit_copy_size", comment: "Copy pixel width/height"), Int64(output.width), Int64(output.height)))
                }
                Text(String(format: NSLocalizedString("stalk_photos_edit_memory_limit", comment: "Current memory export limit, %@ megapixels; 16384 px hard edge and 1400 px preview"), exportBudget.megapixelLabel)).font(.footnote)
                if !source.allowsOriginal(budget: exportBudget) {
                    Text(NSLocalizedString("Сейчас для исходных пикселей недостаточно памяти или превышен лимит размера. Освободите память или явно выберите уменьшенную копию.", comment: "Photo editor memory limit hint")).font(.footnote)
                }
                Button(NSLocalizedString("Проверить доступную память", comment: "Refresh photo export memory budget")) { exportBudget = .current }
                Picker("Папка копии", selection: $folderID) {
                    Text("Корень Диска").tag(String?.none)
                    ForEach(folders) { Text(folderPath($0)).tag(Optional($0.id)) }
                }
                if let folderError {
                    Text(folderError).font(.footnote).foregroundStyle(.red)
                    Button("Загрузить папки повторно") { Task { await loadFolders() } }
                }
                Toggle("Сохранить дату съёмки и данные камеры", isOn: $keepCaptureMetadata)
                Text("Оригинал не изменяется. Геолокация и встроенные миниатюры не переносятся. Замазка всегда непрозрачная.").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var hint: String {
        switch tool {
        case .select: NSLocalizedString("Нажмите на пометку и перетащите её.", comment: "Photo editor hint")
        case .crop: NSLocalizedString("Выделите любую область. Потяните внутри рамки, чтобы переместить её, затем примените обрезку.", comment: "Photo editor hint")
        case .text: NSLocalizedString("Нажмите на фото в месте подписи. Цвет и размер задаются до добавления.", comment: "Photo editor hint")
        case .arrow: NSLocalizedString("Потяните от начала стрелки к её острию.", comment: "Photo editor hint")
        case .rectangle: NSLocalizedString("Потяните от одного угла рамки к другому.", comment: "Photo editor hint")
        case .redact: NSLocalizedString("Выделите область для полностью непрозрачной тёмной замазки.", comment: "Photo editor hint")
        }
    }

    private var displayedCrop: CGRect? {
        if tool == .crop, let start = dragStart, let end = dragEnd, movingCrop == nil {
            return CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(start.x - end.x), height: abs(start.y - end.y))
        }
        return cropRegion
    }

    private func annotation(from: CGPoint, to: CGPoint) -> DiskPhotoEditOperation? {
        switch tool {
        case .arrow: .arrow(from: from, to: to, color: hexColor)
        case .rectangle: .rectangle(from: from, to: to, color: hexColor)
        case .redact: .redact(from: from, to: to)
        default: nil
        }
    }

    private func dragChanged(_ value: DragGesture.Value, display: CGSize, source: DiskPhotoEditSource) {
        func point(_ p: CGPoint) -> CGPoint {
            DiskPhotoEditRenderer.point(CGPoint(x: p.x / display.width, y: p.y / display.height))
        }
        if dragStart == nil {
            let start = point(value.startLocation)
            dragStart = start
            if tool == .select {
                movingObject = DiskPhotoEditGeometry.objects(size: source.size, operations: effective.operations).reversed()
                    .first { $0.bounds.insetBy(dx: -0.015, dy: -0.015).contains(start) }
                selected = movingObject?.index
            } else if tool == .crop, let region = cropRegion, region.contains(start) { movingCrop = region }
            else if tool == .crop { cropRegion = nil }
        }
        let end = point(value.location)
        dragEnd = end
        if let original = movingCrop, let start = dragStart {
            let dx = max(-original.minX, min(1 - original.maxX, end.x - start.x))
            let dy = max(-original.minY, min(1 - original.maxY, end.y - start.y))
            cropRegion = original.offsetBy(dx: dx, dy: dy)
        }
    }

    private func finishDrag() {
        guard let start = dragStart, let end = dragEnd else { return }
        let object = movingObject
        let moving = movingCrop != nil
        let region = displayedCrop
        dragStart = nil; dragEnd = nil; movingObject = nil; movingCrop = nil
        if tool == .text { textAt = start; text = ""; textPrompt = true; return }
        guard abs(end.x - start.x) + abs(end.y - start.y) > 0.008 else { return }
        if let object {
            commitAdjustment()
            history.record(edits)
            edits.operations[object.index] = DiskPhotoEditGeometry.moved(edits.operations[object.index], by: object.delta(CGPoint(x: end.x - start.x, y: end.y - start.y)))
        } else if tool == .crop { if !moving { cropRegion = region } }
        else if let annotation = annotation(from: start, to: end) { append(annotation) }
    }

    private func append(_ operation: DiskPhotoEditOperation) {
        guard effective.operations.count < 60 else { error = NSLocalizedString("Достигнут предел 60 действий. Сохраните копию.", comment: "Photo editor operation limit"); return }
        commitAdjustment()
        history.record(edits)
        edits.operations.append(operation)
        clearPlacement()
        switch operation {
        case .text, .arrow, .rectangle, .redact: tool = .select; selected = edits.operations.count - 1
        default: break
        }
    }

    private func commitAdjustment() {
        guard brightness != 0 || contrast != 0 else { return }
        guard edits.operations.count < 60 else { error = NSLocalizedString("Достигнут предел 60 действий. Сохраните копию.", comment: "Photo editor operation limit"); return }
        history.record(edits)
        edits.operations.append(.adjust(brightness: brightness, contrast: contrast))
        brightness = 0; contrast = 0
    }

    private func applyCrop() {
        guard let region = cropRegion else { return }
        append(.crop(from: region.origin, to: CGPoint(x: region.maxX, y: region.maxY)))
    }

    private func clearPlacement() {
        cropRegion = nil; dragStart = nil; dragEnd = nil; selected = nil; movingObject = nil; movingCrop = nil
    }

    private func clearPending() {
        brightness = 0; contrast = 0; clearPlacement()
    }

    private func undo() {
        if brightness != 0 || contrast != 0 { commitAdjustment() }
        clearPending(); history.undo(&edits)
    }

    private func redo() {
        clearPlacement(); history.redo(&edits)
    }

    private func requestClose() {
        if dirty { discardPrompt = true } else { dismiss() }
    }

    @MainActor private func load() async {
        var downloaded: URL?
        do {
            guard try await canReadSource() else { throw DiskServiceError.http(403) }
            let url: URL
            if let loadOriginal { url = try await loadOriginal() }
            else { url = try await service.originalFile(photo) }
            downloaded = url
            let loaded = try await Task.detached(priority: .userInitiated) { () -> (DiskPhotoEditSource, UIImage) in
                let source = try DiskPhotoEditSource(url: url)
                return try (source, source.image(maxEdge: 1400))
            }.value
            try Task.checkCancellation()
            source = loaded.0; previewBase = loaded.1; preview = loaded.1
            filename = String(format: NSLocalizedString("stalk_photos_edit_filename", comment: "Edited copy basename, %@"), URL(fileURLWithPath: photo.name).deletingPathExtension().lastPathComponent)
            format = photo.mimetype == "image/jpeg" ? .jpeg : .png
            exportBudget = .current
            resolution = loaded.0.allowsOriginal(budget: exportBudget) ? .original : nil
        } catch {
            if let downloaded { DiskPhotoEditSource.cleanupDownload(downloaded, appOwnedCopy: loadOriginal != nil) }
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    @MainActor private func loadFolders() async {
        do {
            let loaded = try await service.disk.fetchFolders()
            try Task.checkCancellation()
            folders = loaded.filter { Int64($0.id).map { $0 > 0 } == true }
            folderError = nil
        } catch {
            if !Task.isCancelled { folderError = String(format: NSLocalizedString("stalk_photos_folders_error", comment: "Folder loading error, %@"), error.localizedDescription) }
        }
    }

    private func folderPath(_ folder: DiskFolder) -> String {
        var parts: [String] = [], seen = Set<String>()
        var current: DiskFolder? = folder
        while let item = current, seen.insert(item.id).inserted {
            parts.insert(item.name, at: 0)
            current = item.parentID.flatMap { parent in folders.first { $0.id == parent } }
        }
        return parts.joined(separator: " / ")
    }

    @MainActor private func renderPreview() async {
        guard let source, let previewBase else { return }
        let snapshot = previewEdits
        do {
            // Coalesce pointer and slider updates before allocating a new raster.
            try await Task.sleep(for: .milliseconds(35))
            let rendering = Task.detached(priority: .userInitiated) {
                try DiskPhotoEditRenderer.render(previewBase, logicalSize: source.size, operations: snapshot.operations, maxEdge: 1400)
            }
            let image = try await withTaskCancellationHandler {
                try await rendering.value
            } onCancel: { rendering.cancel() }
            try Task.checkCancellation()
            preview = image
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }

    @MainActor private func save() async {
        guard canSave, let source, let resolution else { return }
        saving = true; error = nil
        defer { saving = false }
        let snapshot = effective, selectedFormat = format, metadata = keepCaptureMetadata, folder = folderID
        do {
            let name = try selectedFormat.filename(filename)
            guard try await canReadSource() else { throw DiskServiceError.http(403) }
            let data = try await Task.detached(priority: .userInitiated) {
                try source.export(snapshot, format: selectedFormat, resolution: resolution, keepCaptureMetadata: metadata)
            }.value
            try Task.checkCancellation()
            // Rendering can take time; check access again immediately before uploading the copy.
            guard try await canReadSource() else { throw DiskServiceError.http(403) }
            try await service.disk.uploadDiskDoc(filename: name, mimetype: selectedFormat.mime, data: data, folderID: folder)
            saved(); dismiss()
        } catch {
            exportBudget = .current
            self.error = error.localizedDescription
        }
    }

    @MainActor private func canReadSource() async throws -> Bool {
        guard photo.canDownload else { return false }
        if let verifySourceAccess { return await verifySourceAccess() }
        return try await service.canEditCopy(photo)
    }
}
