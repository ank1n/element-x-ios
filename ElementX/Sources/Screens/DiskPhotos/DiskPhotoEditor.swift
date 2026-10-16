// Copyright 2026 ООО «Имплика». SPDX-License-Identifier: AGPL-3.0-only
import CoreImage
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct DiskPhotoEdits: Equatable {
    var turns = 0
    var crop: Double = 0
    var brightness: Double = 0
    var contrast: Double = 1
    var caption = ""
    var x = 0.5
    var y = 0.8

    func image(from original: UIImage, maxEdge: CGFloat = 2048) throws -> UIImage {
        guard var input = CIImage(image: original) else { throw DiskServiceError.http(415) }
        input = input.oriented(forExifOrientation: Int32(original.imageOrientation.exifOrientation))
        input = input.transformed(by: CGAffineTransform(rotationAngle: CGFloat(turns % 4) * .pi / 2))
        var extent = input.extent
        if crop > 0 {
            let ratio = CGFloat(crop)
            if extent.width / extent.height > ratio { let width = extent.height * ratio; extent.origin.x += (extent.width - width) / 2; extent.size.width = width }
            else { let height = extent.width / ratio; extent.origin.y += (extent.height - height) / 2; extent.size.height = height }
            input = input.cropped(to: extent)
        }
        input = input.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: brightness, kCIInputContrastKey: contrast])
        let scale = min(1, maxEdge / max(extent.width, extent.height))
        input = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let image = CIContext(options: [.cacheIntermediates: false]).createCGImage(input, from: input.extent) else { throw DiskServiceError.http(415) }
        let base = UIImage(cgImage: image)
        guard !caption.isEmpty else { return base }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: base.size, format: format).image { _ in
            base.draw(at: .zero)
            let font = UIFont.boldSystemFont(ofSize: max(18, base.size.width / 20))
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white, .strokeColor: UIColor.black, .strokeWidth: -3]
            let size = (caption as NSString).size(withAttributes: attributes)
            (caption as NSString).draw(at: CGPoint(x: min(max(0, base.size.width * x - size.width / 2), max(0, base.size.width - size.width)),
                                                   y: min(max(0, base.size.height * y - size.height / 2), max(0, base.size.height - size.height))), withAttributes: attributes)
        }
    }
}

private extension UIImage.Orientation {
    var exifOrientation: Int {
        switch self { case .up: 1; case .down: 3; case .left: 8; case .right: 6; case .upMirrored: 2; case .downMirrored: 4; case .leftMirrored: 5; case .rightMirrored: 7; @unknown default: 1 }
    }
}

struct DiskPhotoEditor: View {
    let photo: DiskPhoto
    let service: DiskPhotoService
    let saved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var original: UIImage?
    @State private var edits = DiskPhotoEdits()
    @State private var history: [DiskPhotoEdits] = []
    @State private var error: String?
    @State private var saving = false
    @State private var textPrompt = false
    @State private var caption = ""
    @State private var dragging = false
    private func remember() {
        history.append(edits); if history.count > 50 { history.removeFirst() }
    }

    var body: some View {
        NavigationStack {
            VStack {
                if let error { Text(error).foregroundStyle(.red).padding() }
                if let original {
                    GeometryReader { geometry in
                        Image(uiImage: original).resizable().scaledToFit()
                            .rotationEffect(.degrees(Double(edits.turns) * 90)).brightness(edits.brightness).contrast(edits.contrast)
                            .overlay {
                                if !edits.caption.isEmpty {
                                    Text(edits.caption).font(.title.bold()).foregroundStyle(.white).shadow(color: .black, radius: 2)
                                        .position(x: geometry.size.width * CGFloat(edits.x), y: geometry.size.height * CGFloat(edits.y))
                                        .gesture(DragGesture().onChanged { value in
                                            if !dragging { remember(); dragging = true }
                                            edits.x = min(0.95, max(0.05, value.location.x / geometry.size.width))
                                            edits.y = min(0.95, max(0.05, value.location.y / geometry.size.height))
                                        }.onEnded { _ in dragging = false })
                                }
                            }.clipped()
                    }.frame(maxHeight: 360)
                    Form {
                        HStack {
                            Button("Повернуть") { remember(); edits.turns = (edits.turns + 1) % 4 }
                            Button("Текст") { caption = edits.caption; textPrompt = true }
                            Button("Отменить") { if let previous = history.popLast() { edits = previous } }.disabled(history.isEmpty)
                        }
                        Picker("Обрезка по центру", selection: $edits.crop) {
                            Text("Исходная").tag(0.0); Text("Квадрат").tag(1.0); Text("16:9").tag(16.0 / 9); Text("4:3").tag(4.0 / 3)
                        }.onChange(of: edits.crop) { old, _ in var before = edits; before.crop = old; history.append(before) }
                        Text("Яркость")
                        Slider(value: $edits.brightness, in: -0.4...0.4, onEditingChanged: { if $0 { remember() } })
                        Text("Контраст")
                        Slider(value: $edits.contrast, in: 0.5...1.8, onEditingChanged: { if $0 { remember() } })
                        Text("Сохраняется отдельная JPEG-копия до 2048 пикселей. Исходный файл не изменяется.").font(.footnote).foregroundStyle(.secondary)
                    }
                } else if error == nil { ProgressView() }
            }
            .navigationTitle("Редактор копии")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.actionCancel) { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) { Button("Сохранить копию") { Task { await save() } }.disabled(original == nil || saving) }
            }
            .alert("Текст на фото", isPresented: $textPrompt) {
                TextField("Подпись", text: $caption)
                Button(L10n.actionCancel, role: .cancel) { }
                Button("Применить") { remember(); edits.caption = String(caption.prefix(200)) }
            }
            .task {
                do {
                    guard try await service.canEditCopy(photo) else { throw DiskServiceError.http(403) }
                    original = try await service.image(photo)
                } catch { self.error = error.localizedDescription }
            }
        }
    }

    private func save() async {
        guard let original else { return }
        saving = true
        defer { saving = false }
        do {
            guard try await service.canEditCopy(photo) else { throw DiskServiceError.http(403) }
            let image = try edits.image(from: original)
            guard let cg = image.cgImage else { throw DiskServiceError.http(415) }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw DiskServiceError.http(415) }
            var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9, kCGImagePropertyOrientation: 1]
            if let taken = photo.exif?.takenAt, let date = ISO8601DateFormatter().date(from: taken) {
                let format = DateFormatter(); format.dateFormat = "yyyy:MM:dd HH:mm:ss"
                properties[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: format.string(from: date)]
            }
            CGImageDestinationAddImage(destination, cg, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw DiskServiceError.http(415) }
            let basename = URL(fileURLWithPath: photo.name).deletingPathExtension().lastPathComponent
            try await service.disk.uploadDiskDoc(filename: String(format: NSLocalizedString("stalk_photos_copy_filename", comment: "Edited photo filename; keep the .jpg extension"), String(basename.prefix(70))), mimetype: "image/jpeg", data: data as Data)
            saved(); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
