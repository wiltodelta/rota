// Recognize the transcript's first painted frame, without AX or wheel events that can unblank a lazy stack.
// Usage: check-transcript-paint <pid> <output.png>
import AppKit
import Vision

let arguments = CommandLine.arguments
guard arguments.count == 3, let pid = Int(arguments[1]) else {
    fputs("Usage: check-transcript-paint <pid> <output.png>\n", stderr)
    exit(1)
}
let output = URL(fileURLWithPath: arguments[2])
let deadline = Date().addingTimeInterval(20)
var recognized = ""
while Date() < deadline {
    let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
    let window = windows.first {
        guard $0[kCGWindowOwnerPID as String] as? Int == pid,
              $0[kCGWindowLayer as String] as? Int == 0,
              let bounds = $0[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: bounds) else { return false }
        return frame.width >= 820 && frame.height >= 520
    }
    if let id = window?[kCGWindowNumber as String] as? UInt32 {
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-o", "-x", "-l", String(id), output.path]
        try capture.run()
        capture.waitUntilExit()
        if capture.terminationStatus == 0 {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = false
            // Exclude the sidebar (which already has the same preview), header and composer.
            request.regionOfInterest = CGRect(x: 0.36, y: 0.22, width: 0.63, height: 0.50)
            try VNImageRequestHandler(url: output).perform([request])
            recognized = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ")
            if recognized.contains("Paint check passed") {
                print("Transcript painted before any AX query or scroll input")
                exit(0)
            }
        }
    }
    Thread.sleep(forTimeInterval: 0.2)
}
fputs("Transcript stayed blank or omitted its final message. Recognized body: \(recognized)\n", stderr)
exit(1)
