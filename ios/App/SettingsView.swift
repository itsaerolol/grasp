import SwiftUI

/// What the share extension does automatically. Every change is saved at once to the App Group, so the next
/// share uses it; there's no Save button.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = SendSettings.load()

    var body: some View {
        NavigationStack {
            Form {
                photos
                linksAndText
                folders
                fromPC
                Section {
                    Button("Restore Defaults", role: .destructive) { settings = .defaults }
                        .disabled(settings == .defaults)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: settings) { _, new in new.save() }
        }
    }

    private var photos: some View {
        Section {
            Picker("Format", selection: $settings.photoFormat) {
                Text("JPG").tag(SendSettings.PhotoFormat.jpg)
                Text("Original").tag(SendSettings.PhotoFormat.original)
            }
            if settings.photoFormat == .jpg {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("JPG Quality")
                        Spacer()
                        Text(settings.jpegQuality, format: .percent.precision(.fractionLength(0)))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.jpegQuality, in: SendSettings.jpegQualityRange, step: 0.05)
                }
            }
            Toggle("Remove Location", isOn: $settings.stripLocation)
            Toggle("Name by Date Taken", isOn: $settings.namePhotosByDate)
        } header: {
            Text("Photos")
        } footer: {
            Text(photoFooter)
        }
    }

    private var photoFooter: String {
        let format = settings.photoFormat == .jpg
            ? "HEIC and WebP photos are converted to JPG, which opens everywhere on Windows."
            : "Photos are sent as they are. HEIC needs a codec to open on Windows."
        return format + " Remove Location strips GPS from photos (videos keep theirs). Name by Date Taken sends"
            + " \"Photo 2026-10-20 20.49.30.jpg\" instead of \"IMG_1234.jpg\"."
    }

    private var linksAndText: some View {
        Section {
            Toggle("Send as Message", isOn: $settings.textAsMessage)
        } header: {
            Text("Links & Text")
        } footer: {
            Text(settings.textAsMessage
                 ? "A single link or piece of text pops up on the PC and is copied to its clipboard. Links open in the browser."
                 : "A single link or piece of text arrives as Note.txt in the save folder.")
        }
    }

    private var fromPC: some View {
        Section {
            Toggle("Save Photos & Videos to Photos", isOn: $settings.saveMediaToPhotos)
        } header: {
            Text("From PC")
        } footer: {
            Text("Everything the PC sends lands in Files › On My iPhone › Grasp."
                 + (settings.saveMediaToPhotos ? " Photos and videos are also added to your library." : ""))
        }
    }

    private var folders: some View {
        Section {
            Picker("Send Folders As", selection: $settings.folderMode) {
                Text("One .zip").tag(SendSettings.FolderMode.zip)
                Text("Separate Files").tag(SendSettings.FolderMode.files)
            }
        } header: {
            Text("Folders")
        } footer: {
            Text(settings.folderMode == .zip
                 ? "A folder arrives as one .zip with its subfolders inside."
                 : "Every file in the folder arrives on its own, subfolders flattened into one level. Files with the same name get a number.")
        }
    }
}
