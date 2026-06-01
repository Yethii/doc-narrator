//
//  Doc_NarratorApp.swift
//  Doc Narrator
//
//  Created by AIM on 5/30/26.
//

import SwiftUI
import AVFoundation
import UserNotifications

/// Presents "summary ready" notifications as banners even while the app is in the foreground.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationDelegate()
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner] }   // no sound — would pause narration
}

@main
struct Doc_NarratorApp: App {
    init() {
        // Touch the shared Kokoro engine now so its 17 MB ONNX model loads in the
        // background while the user browses the library, not when they tap Play.
        _ = KokoroTTSEngine.shared
        _ = PlaybackCoordinator.shared   // registers MPRemoteCommandCenter handlers at launch
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared

        do {
            // Plain .playback (no .duckOthers): makes us the system's primary
            // "Now Playing" app so Control Center / lock screen route transport
            // commands to us. .duckOthers would mark us as a secondary/ducking
            // source (like a GPS app) and we'd never own the Now Playing slot.
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
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
