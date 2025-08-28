import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Foundation

// MARK: - File-scope helpers and types

// Convert seconds to timeline ticks using the loaded reference timescale
private func secondsToTicks(_ seconds: TimeInterval, timescale: Int) -> Int {
    Int(round(seconds * Double(timescale)))
}

// Snap any tick count to a frame boundary using frameTicks from the reference
private func snapToFrame(_ ticks: Int, frameTicks: Int) -> Int {
    let frames = Double(ticks) / Double(frameTicks)
    return Int(round(frames)) * frameTicks
}

// Format ticks back to rational time "ticks/timescale s"
private func ticksToRational(_ ticks: Int, timescale: Int) -> String {
    "\(ticks)/\(timescale)s"
}

// Parse SRT style times like 00:01:02,345 or 00:01:02.345
private func parseSRTTime(_ t: String) -> TimeInterval? {
    let t2 = t.replacingOccurrences(of: ",", with: ".")
    let parts = t2.split(separator: ":").map(String.init)
    guard parts.count == 3 else { return nil }
    let h = Double(parts[0]) ?? 0
    let m = Double(parts[1]) ?? 0
    let s = Double(parts[2]) ?? 0
    return h * 3600 + m * 60 + s
}

// Accepts 01:02:03.456, 01:02:03,456, 01:02:03.456s, or SMPTE 01:02:03:24
private func parseAnyTimecode(_ t: String, fps: Double = 30.0) -> TimeInterval? {
    var s = t.trimmingCharacters(in: .whitespaces)
    if s.hasSuffix("s") { s.removeLast() }
    s = s.replacingOccurrences(of: ",", with: ".")
    let parts = s.split(separator: ":").map(String.init)

    if parts.count == 3 {
        let h = Double(parts[0]) ?? 0
        let m = Double(parts[1]) ?? 0
        let sec = Double(parts[2]) ?? 0
        return h * 3600 + m * 60 + sec
    } else if parts.count == 4 {
        let h = Double(parts[0]) ?? 0
        let m = Double(parts[1]) ?? 0
        let sec = Double(parts[2]) ?? 0
        let f = Double(parts[3]) ?? 0
        let fr = max(fps, 1.0)
        return h * 3600 + m * 60 + sec + (f / fr)
    } else {
        return nil
    }
}

private func escapeXML(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
     .replacingOccurrences(of: "<", with: "&lt;")
     .replacingOccurrences(of: ">", with: "&gt;")
     .replacingOccurrences(of: "\"", with: "&quot;")
     .replacingOccurrences(of: "'", with: "&apos;")
}

private func firstLine(_ s: String) -> String {
    s.components(separatedBy: .newlines).first ?? s
}

struct CaptionCue {
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}

struct FCPReference {
    var timescale: Int = 30000     // denominator in ticks per second
    var frameTicks: Int = 1001     // ticks per frame
    var effectUID: String = ".../Titles.localized/Basic Text.localized/Text.localized/Text.moti"  // Text effect
    var formatName: String = "FFVideoFormat1080p2997"
    var frameDurationString: String { "\(frameTicks)/\(timescale)s" }
    
    // Initialize from ITT metadata
    init(fromITT ittData: Data) {
        let parser = ITTMetadataParser()
        parser.parse(data: ittData)
        
        // Set timing based on ITT frame rate
        self.timescale = parser.timescale
        self.frameTicks = parser.frameTicks
        self.formatName = parser.formatName
    }
    
    // Default initializer for backward compatibility
    init() {
        self.timescale = 30000
        self.frameTicks = 1001
        self.effectUID = "rmd/Title/Basic Title"
        self.formatName = "FFVideoFormat1080p2997"
    }
}

// New parser to extract metadata from ITT files
class ITTMetadataParser: NSObject, XMLParserDelegate {
    var timescale: Int = 30000
    var frameTicks: Int = 1001
    var formatName: String = "FFVideoFormat1080p2997"
    
    func parse(data: Data) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        _ = parser.parse()
    }
    
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        if name == "tt" {
            // Extract frame rate from ITT
            if let frameRateStr = attributeDict["ttp:frameRate"] {
                let frameRate = Double(frameRateStr) ?? 30.0
                
                // Convert frame rate to timescale and frameTicks
                // For 30fps: timescale = 30000, frameTicks = 1000
                // For 29.97fps: timescale = 30000, frameTicks = 1001
                if frameRate == 30.0 {
                    self.timescale = 30000
                    self.frameTicks = 1000
                    self.formatName = "FFVideoFormat1080p30"
                } else if abs(frameRate - 29.97) < 0.01 {
                    self.timescale = 30000
                    self.frameTicks = 1001
                    self.formatName = "FFVideoFormat1080p2997"
                } else if frameRate == 25.0 {
                    self.timescale = 25000
                    self.frameTicks = 1000
                    self.formatName = "FFVideoFormat1080p25"
                } else if frameRate == 24.0 {
                    self.timescale = 24000
                    self.frameTicks = 1000
                    self.formatName = "FFVideoFormat1080p24"
                } else {
                    // Custom frame rate - calculate appropriate values
                    self.timescale = Int(frameRate * 1000)
                    self.frameTicks = 1000
                    self.formatName = "FFVideoFormat1080p\(Int(frameRate))"
                }
            }
        }
    }
}

// MARK: - Parsers

private func looksLikeSRT(_ s: String) -> Bool {
    s.contains("-->") && s.range(of: #"^\s*\d+\s*$"#, options: .regularExpression) != nil
}

private func parseSRT(_ s: String) throws -> [CaptionCue] {
    let normalised = s.replacingOccurrences(of: "\r\n", with: "\n")
    let blocks = normalised.components(separatedBy: "\n\n")
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var result: [CaptionCue] = []

    for block in blocks {
        let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2 else { continue }

        let timingLineIndex = lines[0].contains("-->") ? 0 : 1
        guard lines.indices.contains(timingLineIndex),
              lines[timingLineIndex].contains("-->") else { continue }

        let timing = lines[timingLineIndex]
        let parts = timing.components(separatedBy: "-->")
        guard parts.count == 2 else { continue }

        let start = parseSRTTime(parts[0].trimmingCharacters(in: .whitespaces))
        let end = parseSRTTime(parts[1].trimmingCharacters(in: .whitespaces))

        let textLines = lines.dropFirst(timingLineIndex + 1)
        let text = textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        if let sVal = start, let eVal = end, eVal > sVal {
            result.append(CaptionCue(start: sVal, end: eVal, text: text))
        }
    }
    return result
}

private func looksLikeITT(_ data: Data) -> Bool {
    guard let s = String(data: data, encoding: .utf8) else { return false }
    return s.contains("<tt") && s.contains("<p")
}

private func parseITT(_ data: Data) throws -> [CaptionCue] {
    class ITTParser: NSObject, XMLParserDelegate {
        var cues: [CaptionCue] = []
        var currentText: String = ""
        var currentBegin: String?
        var currentEnd: String?
        var fps: Double = 30.0
        var inP: Bool = false

        func parser(_ parser: XMLParser,
                    didStartElement name: String,
                    namespaceURI: String?,
                    qualifiedName qName: String?,
                    attributes attributeDict: [String : String] = [:]) {

            let lower = name.lowercased()

            if lower == "tt" {
                let fr = attributeDict["ttp:frameRate"] ?? attributeDict["frameRate"]
                let frm = attributeDict["ttp:frameRateMultiplier"] ?? attributeDict["frameRateMultiplier"]

                var frameRate: Double = Double(fr ?? "") ?? 30.0
                if let mul = frm {
                    let parts = mul.split(separator: " ").map { Double($0) ?? 1.0 }
                    if parts.count == 2, parts[1] != 0 {
                        frameRate *= (parts[0] / parts[1])
                    }
                }
                fps = frameRate
            } else if lower == "p" {
                inP = true
                currentText = ""
                currentBegin = attributeDict["begin"]
                currentEnd = attributeDict["end"]
            } else if lower == "br", inP {
                currentText += "\n"
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inP { currentText += string }
        }

        func parser(_ parser: XMLParser,
                    didEndElement name: String,
                    namespaceURI: String?,
                    qualifiedName qName: String?) {
            if name.lowercased() == "p" {
                inP = false
                let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
                if let b = currentBegin, let e = currentEnd,
                   let bs = parseAnyTimecode(b, fps: fps),
                   let es = parseAnyTimecode(e, fps: fps),
                   es > bs {
                    cues.append(CaptionCue(start: bs, end: es, text: text))
                }
                currentText = ""
                currentBegin = nil
                currentEnd = nil
            }
        }
    }

    let parser = XMLParser(data: data)
    let delegate = ITTParser()
    parser.delegate = delegate
    _ = parser.parse()
    return delegate.cues
}

// MARK: - FCPXML builder that uses a loaded reference

private func buildFCPXML(from cues: [CaptionCue], ref: FCPReference, projectName: String) -> String {
    // Sort cues to enforce order on the spine
    let scues = cues.sorted { $0.start < $1.start }

    // Sequence duration snapped to a frame boundary
    let totalSec = max(scues.map { $0.end }.max() ?? 0, 1)
    let totalTicks = snapToFrame(
        secondsToTicks(totalSec, timescale: ref.timescale),
        frameTicks: ref.frameTicks
    )
    let seqDuration = ticksToRational(totalTicks, timescale: ref.timescale)

    var xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE fcpxml>
    <fcpxml version="1.13">
      <resources>
        <format id="r1" name="\(ref.formatName)" frameDuration="\(ref.frameDurationString)" width="1920" height="1080" colorSpace="1-1-1 (Rec. 709)"/>
        <effect id="r2" name="Text" uid="\(ref.effectUID)"/>
      </resources>
      <library>
        <event name="\(projectName)">
          <project name="\(projectName)">
            <sequence format="r1" duration="\(seqDuration)" tcStart="0s" tcFormat="NDF" audioLayout="stereo" audioRate="48k">
              <spine>
    """

    // Add a leading gap if the first caption starts after 0:00
    if let first = scues.first {
        let firstStartTicks = snapToFrame(
            secondsToTicks(first.start, timescale: ref.timescale),
            frameTicks: ref.frameTicks
        )
        if firstStartTicks > 0 {
            let gapDur = ticksToRational(firstStartTicks, timescale: ref.timescale)
            xml += """
                    <gap name="Gap" offset="0s" duration="\(gapDur)"/>
            """
        }
    }

    // Emit titles directly on the spine using offset for placement
    for (i, cue) in scues.enumerated() {
        let offsetTicks = snapToFrame(
            secondsToTicks(cue.start, timescale: ref.timescale),
            frameTicks: ref.frameTicks
        )
        var durTicks = snapToFrame(
            secondsToTicks(cue.end - cue.start, timescale: ref.timescale),
            frameTicks: ref.frameTicks
        )
        if durTicks == 0 { durTicks = ref.frameTicks } // at least one frame

        let offset   = ticksToRational(offsetTicks, timescale: ref.timescale)
        let duration = ticksToRational(durTicks,    timescale: ref.timescale)
        let textEsc  = escapeXML(cue.text)
        let clipName = firstLine(textEsc).isEmpty ? "Caption \(i+1)" : firstLine(textEsc)

        xml += """
                <title ref="r2" name="\(clipName)" offset="\(offset)" start="0s" duration="\(duration)">
                  <text>
                    <text-style ref="ts\(i+1)">\(textEsc)</text-style>
                  </text>
                  <text-style-def id="ts\(i+1)">
                    <text-style font="Helvetica Neue" fontSize="96" fontColor="1 1 1 1" alignment="center"/>
                  </text-style-def>
                </title>

        """
    }

    xml += """
              </spine>
            </sequence>
          </project>
        </event>
      </library>
    </fcpxml>
    """
    return xml
}

// MARK: - UI

struct ContentView: View {
    @State private var cues: [CaptionCue] = []
    @State private var status: String = "Load an ITT file to convert captions to FCP titles"
    @State private var ref = FCPReference()

    var body: some View {
        VStack(spacing: 14) {
            Text("ITT Captions to FCP Titles")
                .font(.title2)
            Text(status)
                .font(.callout)
                .foregroundColor(.secondary)
                .lineLimit(3)

            VStack(spacing: 16) {
                VStack(spacing: 8) {
                    Text("Step 1: Load your ITT captions file")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    
                    Button("Load ITT File") { openCaptions() }
                        .keyboardShortcut("o")
                }
                
                VStack(spacing: 8) {
                    Text("Step 2: Export as FCP XML (when ready)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    
                    Button("Export FCP XML") { exportFCPXML() }
                        .disabled(cues.isEmpty)
                        .keyboardShortcut("e")
                }
            }
            
            Spacer()
            
            Button("View License") { showLicense() }
                .buttonStyle(.plain)
                .foregroundColor(.blue)
                .underline()
                .keyboardShortcut("l")
        }
        .padding(24)
        .frame(width: 560, height: 200)
    }



    // Load SRT or ITT
    private func openCaptions() {
        let panel = NSOpenPanel()
        var allowed: [String] = []

        // Basic text types
        allowed.append("srt")
        allowed.append("itt")
        allowed.append("xml")
        allowed.append("txt")

        panel.allowedFileTypes = allowed
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true

        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            if url.startAccessingSecurityScopedResource() {
                defer { url.stopAccessingSecurityScopedResource() }
                loadCaptions(from: url)
            } else {
                status = "No permission to read the captions"
            }
        }
    }

    private func loadCaptions(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let string = String(decoding: data, as: UTF8.self)

            if url.pathExtension.lowercased() == "srt" || looksLikeSRT(string) {
                cues = try parseSRT(string)
                status = "Loaded \(cues.count) cues from SRT"
            } else if url.pathExtension.lowercased() == "itt" || looksLikeITT(data) {
                cues = try parseITT(data)
                // Automatically set up FCP reference from ITT metadata
                ref = FCPReference(fromITT: data)
                status = "Loaded \(cues.count) cues from ITT (Frame rate: \(ref.formatName))"
            } else {
                if let parsedSRT = try? parseSRT(string), !parsedSRT.isEmpty {
                    cues = parsedSRT
                    status = "Loaded \(cues.count) cues from SRT"
                } else if let parsedITT = try? parseITT(data), !parsedITT.isEmpty {
                    cues = parsedITT
                    // Automatically set up FCP reference from ITT metadata
                    ref = FCPReference(fromITT: data)
                    status = "Loaded \(cues.count) cues from ITT (Frame rate: \(ref.formatName))"
                } else {
                    status = "Could not detect SRT or ITT"
                    cues = []
                }
            }
        } catch {
            status = "Failed to read captions"
            cues = []
        }
    }

    // Save FCPXML that matches your reference. Project/Event names mirror the chosen file name.
    private func exportFCPXML() {
        guard !cues.isEmpty else { return }

        let save = NSSavePanel()
        let suggested = "captions_as_titles.fcpxml"
        save.nameFieldStringValue = suggested

        // Keep it simple and reliable
        save.allowedFileTypes = ["fcpxml"]
        save.allowsOtherFileTypes = false
        save.canCreateDirectories = true
        save.isExtensionHidden = false
        save.treatsFilePackagesAsDirectories = true

        save.begin { resp in
            guard resp == .OK, var url = save.url else { return }

            // Ensure the extension is .fcpxml
            if url.pathExtension.lowercased() != "fcpxml" {
                url.deletePathExtension()
                url.appendPathExtension("fcpxml")
            }

            // Use the chosen file name as the Event and Project name
            let projectName = url.deletingPathExtension().lastPathComponent
            let fcpx = buildFCPXML(from: cues, ref: ref, projectName: projectName)

            if url.startAccessingSecurityScopedResource() {
                defer { url.stopAccessingSecurityScopedResource() }
                do {
                    if let data = fcpx.data(using: .utf8) {
                        try data.write(to: url)
                        status = "Saved FCPXML"
                        showSuccessDialog(filename: url.lastPathComponent, captionCount: cues.count)
                    } else {
                        status = "Could not encode XML to UTF-8"
                    }
                } catch {
                    status = "Failed to save FCPXML"
                }
            } else {
                status = "No permission to save there"
            }
        }
    }
    
    // Show MIT License information
    private func showLicense() {
        let licenseWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        
        licenseWindow.title = "MIT License - CaptionConvert2"
        licenseWindow.center()
        licenseWindow.isReleasedWhenClosed = false
        
        let licenseView = LicenseView()
        licenseWindow.contentView = NSHostingView(rootView: licenseView)
        licenseWindow.makeKeyAndOrderFront(nil)
    }
    
    // Show success dialog when FCP XML is created
    private func showSuccessDialog(filename: String, captionCount: Int) {
        let successWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        
        successWindow.title = "Success! - CaptionConvert2"
        successWindow.center()
        successWindow.isReleasedWhenClosed = false
        
        let successView = SuccessView(filename: filename, captionCount: captionCount)
        successWindow.contentView = NSHostingView(rootView: successView)
        successWindow.makeKeyAndOrderFront(nil)
    }
}

struct LicenseView: View {
    var body: some View {
        VStack(spacing: 20) {
            Text("MIT License")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("CaptionConvert2")
                .font(.title2)
                .foregroundColor(.secondary)
            
            Text("Copyright (c) 2025 joycamp")
                .font(.body)
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
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

struct SuccessView: View {
    let filename: String
    let captionCount: Int
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(.green)
            
            Text("Success!")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("FCP XML file created successfully")
                .font(.body)
                .multilineTextAlignment(.center)
            
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Filename:")
                        .fontWeight(.semibold)
                    Text(filename)
                        .foregroundColor(.secondary)
                }
                
                HStack {
                    Text("Captions converted:")
                        .fontWeight(.semibold)
                    Text("\(captionCount)")
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal)
            
            Button("OK") {
                NSApp.keyWindow?.close()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(width: 450, height: 320)
    }
}
