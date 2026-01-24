// MacParakeet - Fast, Private, Local Transcription
// Main application entry point

import SwiftUI

@main
struct MacParakeetApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        // Menu bar presence
        MenuBarExtra("MacParakeet", systemImage: "waveform") {
            MenuBarView()
        }
    }
}

struct ContentView: View {
    @State private var isDragging = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.circle.fill")
                .resizable()
                .frame(width: 80, height: 80)
                .foregroundStyle(.blue)

            Text("MacParakeet")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Drop audio or video file here")
                .foregroundStyle(.secondary)

            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                .foregroundStyle(isDragging ? .blue : .secondary)
                .frame(width: 300, height: 150)
                .overlay {
                    VStack {
                        Image(systemName: "arrow.down.doc")
                            .font(.system(size: 40))
                            .foregroundStyle(isDragging ? .blue : .secondary)
                        Text("Drag & Drop")
                            .foregroundStyle(.secondary)
                    }
                }
                .onDrop(of: [.fileURL], isTargeted: $isDragging) { providers in
                    // TODO: Handle file drop
                    return true
                }

            Button("Browse Files") {
                // TODO: Open file picker
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(minWidth: 400, minHeight: 400)
    }
}

struct MenuBarView: View {
    var body: some View {
        VStack {
            Button("Start Dictation") {
                // TODO: Start dictation
            }
            .keyboardShortcut("d", modifiers: [.option])

            Divider()

            Button("Open Window") {
                // TODO: Show main window
            }
            .keyboardShortcut("o", modifiers: .command)

            Divider()

            Button("Settings...") {
                // TODO: Open settings
            }
            .keyboardShortcut(",", modifiers: .command)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}

#Preview {
    ContentView()
}
