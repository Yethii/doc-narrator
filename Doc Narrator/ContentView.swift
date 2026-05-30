//
//  ContentView.swift
//  Doc Narrator
//
//  Created by AIM on 5/30/26.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        LibraryView()
            .environmentObject(LibraryStore.shared)
    }
}
