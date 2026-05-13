import Foundation

public enum FilenameSanitizer {
    public static func sanitize(_ input: String, maxLength: Int = 180) -> String {
        let normalized = input.precomposedStringWithCanonicalMapping
        let pieces = normalized
            .split { character in
                character == "/" || character == "\\"
            }
            .compactMap { rawPiece -> String? in
                var piece = String(rawPiece)
                    .replacingOccurrences(of: ":", with: "_")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                guard piece != ".", piece != ".." else { return nil }

                while piece.contains("..") {
                    piece = piece.replacingOccurrences(of: "..", with: "_")
                }

                while piece.first == "." || piece.first == " " {
                    piece.removeFirst()
                }

                return piece.isEmpty ? nil : piece
            }

        var name = pieces.joined(separator: "_")

        if name.isEmpty {
            name = "untitled"
        }

        if name.count <= maxLength {
            return name
        }

        let url = URL(fileURLWithPath: name)
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent

        guard !ext.isEmpty, ext.count < 32 else {
            return String(name.prefix(maxLength))
        }

        let suffix = "." + ext
        let stemLimit = max(1, maxLength - suffix.count)
        return String(stem.prefix(stemLimit)) + suffix
    }
}

public enum CollisionName {
    public static func candidate(for safeName: String, attempt: Int) -> String {
        guard attempt > 0 else { return safeName }

        let url = URL(fileURLWithPath: safeName)
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        if ext.isEmpty {
            return "\(stem) (\(attempt))"
        }
        return "\(stem) (\(attempt)).\(ext)"
    }
}
