//
//  CaptionConvert2App.swift
//  CaptionConvert2
//
//  Created by Ken Raley on 28/8/2025.
//

import SwiftUI

@main
struct CaptionConvert2App: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 20) {
            Text("CaptionConvert2")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("A Swift app that converts ITT Captions to Final Cut Titles")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
            
            Text("Version 1.0")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("MIT License")
                        .font(.headline)
                        .fontWeight(.semibold)
                    
                    Text("Copyright (c) 2025 joycamp")
                        .font(.body)
                    
                    Text("Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the \"Software\"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
            }
            .frame(maxHeight: 200)
            
            Button("OK") {
                NSApp.keyWindow?.close()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(30)
        .frame(width: 500, height: 400)
    }
}
