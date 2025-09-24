//
//  PhotoPickerView.swift
//  PhotoToCalendar
//
//  Created by Georgy on 24.09.2025.
//

import SwiftUI
import PhotosUI
import UIKit

struct PhotoPickerView: View {
    @Binding var image: UIImage?
    @State private var selection: PhotosPickerItem?
    @State private var isLoading = false
    @State private var showError = false
    @State private var errorMessage: String?

    var body: some View {
        PhotosPicker(selection: $selection, matching: .images) {
            Label("Выбрать фото", systemImage: "photo.on.rectangle")
        }
        .overlay {
            if isLoading {
                ProgressView().padding(.horizontal, 8)
            }
        }
        .task(id: selection) {
            guard let item = selection else { return }
            isLoading = true
            defer { isLoading = false }
            do {
                if let data = try await item.loadTransferable(type: Data.self),
                   let uiImage = UIImage(data: data) {
                    await MainActor.run {
                        image = uiImage
                        selection = nil
                    }
                    return
                }
                if let url = try? await item.loadTransferable(type: URL.self),
                   let data = try? Data(contentsOf: url),
                   let uiImage = UIImage(data: data) {
                    await MainActor.run {
                        image = uiImage
                        selection = nil
                    }
                    return
                }
                throw NSError(domain: "PhotoPicker",
                              code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Не удалось получить изображение"])
            } catch {
                await MainActor.run {
                    errorMessage = (error as NSError).localizedDescription
                    showError = true
                }
            }
        }
        .alert("Ошибка загрузки фото", isPresented: $showError, actions: {
            Button("OK", role: .cancel) { }
        }, message: {
            Text(errorMessage ?? "Неизвестная ошибка")
        })
    }
}
