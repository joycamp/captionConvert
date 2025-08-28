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
    var effectUID: String = "rmd/Title/Basic Title"  // replaced by your reference
    var formatName: String = "FFVideoFormat1080p2997"
    var frameDurationString: String { "\(frameTicks)/\(timescale)s" }
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
                    <text-style font="Helvetica Neue" fontSize="96" fontColor="1 1 1 1" alignment="center">\(textEsc)</text-style>
                  </text>
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
    @State private var status: String = "Load a reference FCPXML once, then load SRT or ITT"
    @State private var ref = FCPReference()

    var body: some View {
        VStack(spacing: 14) {
            Text("Captions to FCP Titles")
                .font(.title2)
            Text(status)
                .font(.callout)
                .foregroundColor(.secondary)
                .lineLimit(3)

            HStack {
                Button("Load Reference FCPXML…") { openReference() }
                    .keyboardShortcut("r")
                Button("Load Captions…") { openCaptions() }
                    .keyboardShortcut("o")
                Button("Export FCPXML…") { exportFCPXML() }
                    .disabled(cues.isEmpty)
                    .keyboardShortcut("e")
            }
        }
        .padding(24)
        .frame(width: 560, height: 200)
    }

    // Load your project reference so we match frameDuration and effect UID
    private func openReference() {
        let panel = NSOpenPanel()

        // Accept both .fcpxmld and .fcpxml from Final Cut, plus plain .xml
        panel.allowedFileTypes = ["fcpxmld", "fcpxml", "xml"]
        panel.allowsOtherFileTypes = false
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true

        panel.begin { resp in
            guard resp == .OK, let url = panel.url else { return }
            if url.startAccessingSecurityScopedResource() {
                defer { url.stopAccessingSecurityScopedResource() }
                do {
                    let data = try Data(contentsOf: url)
                    parseReferenceFCPXML(data)
                    status = "Reference loaded"
                } catch {
                    status = "Failed to read reference file"
                }
            } else {
                status = "No permission to read the reference"
            }
        }
    }

    private func parseReferenceFCPXML(_ data: Data) {
        class RefParser: NSObject, XMLParserDelegate {
            var timescale = 30000
            var frameTicks = 1001
            var effectUID: String?
            var formatName: String = "FFVideoFormat1080p2997"

            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String : String] = [:]) {
                if name == "format" {
                    if let fd = attributes["frameDuration"] {
                        let clean = fd.replacingOccurrences(of: "s", with: "")
                        let parts = clean.split(separator: "/").map(String.init)
                        if parts.count == 2, let n = Int(parts[0]), let d = Int(parts[1]) {
                            frameTicks = max(n, 1)
                            timescale = max(d, 1)
                        }
                    }
                    if let nm = attributes["name"] {
                        formatName = nm
                    }
                } else if name == "effect" {
                    if let uid = attributes["uid"], let nm = attributes["name"] {
                        // Prefer a Title or Text effect
                        if nm.lowercased().contains("title") || nm.lowercased().contains("text") {
                            effectUID = uid
                        }
                    }
                }
            }
        }

        let p = RefParser()
        let xp = XMLParser(data: data)
        xp.delegate = p
        _ = xp.parse()

        ref.timescale = p.timescale
        ref.frameTicks = p.frameTicks
        ref.formatName = p.formatName
        if let uid = p.effectUID { ref.effectUID = uid }
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
                status = "Loaded \(cues.count) cues from ITT"
            } else {
                if let parsedSRT = try? parseSRT(string), !parsedSRT.isEmpty {
                    cues = parsedSRT
                    status = "Loaded \(cues.count) cues from SRT"
                } else if let parsedITT = try? parseITT(data), !parsedITT.isEmpty {
                    cues = parsedITT
                    status = "Loaded \(cues.count) cues from ITT"
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
}
