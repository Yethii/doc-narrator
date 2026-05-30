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
        }
    }
}
