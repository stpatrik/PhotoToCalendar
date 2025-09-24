//
//  PhotoPickerView.swift
//  PhotoToCalendar
//
//  Created by Georgy on 24.09.2025.
//

import SwiftUI
import PhotosUI

struct PhotoPickerView: View {
    @Binding var image: UIImage?
    @State private var selection: PhotosPickerItem?
    
    var body: some View {
        PhotosPicker(selection: $selection, matching: .images) {
            Label("Выбрать фото", systemImage: "photo.on.rectangle")
        }
        .onChange(of: selection) { _, newItem in
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self),
                   let ui = UIImage(data: data) {
                    image = ui
                }
            }
        }
    }
}
