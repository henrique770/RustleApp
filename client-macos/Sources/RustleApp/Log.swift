import Foundation

/// Appends to ~/Library/Logs/RustleApp.log so problems are visible without Console.app.
enum Log {
    static let url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/RustleApp.log")
    private static let queue = DispatchQueue(label: "rustle.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) {
        let line = "\(stamp.string(from: Date())) \(message)\n"
        NSLog("RustleApp: %@", message)
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
