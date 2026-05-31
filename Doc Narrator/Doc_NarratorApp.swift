//
//  Doc_NarratorApp.swift
//  Doc Narrator
//
//  Created by AIM on 5/30/26.
//

import SwiftUI
import AVFoundation

@main
struct Doc_NarratorApp: App {
    init() {
        // Touch the shared Kokoro engine now so its 17 MB ONNX model loads in the
        // background while the user browses the library, not when they tap Play.
        _ = KokoroTTSEngine.shared
        _ = PlaybackCoordinator.shared   // registers MPRemoteCommandCenter handlers at launch

        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.duckOthers]
            )
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            print("AudioSession error: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    LibraryStore.shared.importFromURL(url)
                }
        }
    }
}
