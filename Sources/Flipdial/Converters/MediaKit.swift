import CoreGraphics
import Foundation

enum MediaKit {
    static func ffmpeg(_ args: [String]) async throws {
        let ff = try Engines.require(.ffmpeg)
        try await Shell.run(ff, ["-hide_banner", "-loglevel", "error", "-y"] + args)
    }

    struct Probe {
        let duration: Double
        let hasAudio: Bool
        let width: Int
        let height: Int
    }

    /// Reads duration, size and stream info from `ffmpeg -i`, so FFprobe isn't needed.
    static func probe(_ url: URL) async throws -> Probe {
        let ff = try Engines.require(.ffmpeg)
        let info = try await Shell.execute(ff, ["-hide_banner", "-i", url.path]).stderr
        var duration = 0.0
        if let d = EPUB.firstMatch(#"Duration: (\d+:\d+:[\d.]+)"#, in: info) {
            duration = d.split(separator: ":").compactMap { Double($0) }.reduce(0) { $0 * 60 + $1 }
        }
        var width = 0, height = 0
        if let video = info.components(separatedBy: "\n").first(where: { $0.contains("Video:") }),
           let size = EPUB.firstMatch(#"[, ](\d{2,5}x\d{2,5})[, ]"#, in: video) {
            let parts = size.split(separator: "x").compactMap { Int($0) }
            if parts.count == 2 { width = parts[0]; height = parts[1] }
        }
        return Probe(duration: duration, hasAudio: info.contains("Audio:"), width: width, height: height)
    }

    static func duration(of url: URL) async throws -> Double {
        let seconds = try await probe(url).duration
        guard seconds > 0 else { throw FlipdialError("Couldn't read the duration of \(url.lastPathComponent)") }
        return seconds
    }

    /// A still from about a second in, for previews such as the crop window.
    static func frame(of url: URL) async throws -> CGImage {
        try await Temp.with { dir in
            let jpg = dir.appendingPathComponent("frame.jpg")
            let length = (try? await duration(of: url)) ?? 0
            try await ffmpeg(["-ss", String(format: "%.2f", min(1, length / 2)), "-i", url.path, "-frames:v", "1", "-q:v", "2", jpg.path])
            return try ImageKit.load(jpg).image
        }
    }

    private static let evenSize = "scale=trunc(iw/2)*2:trunc(ih/2)*2"

    static func videoArgs(_ ext: String) -> [String] {
        let h264 = ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p", "-vf", evenSize]
        switch ext {
        case "mp4", "m4v": return h264 + ["-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
        case "mov", "mkv": return h264 + ["-c:a", "aac", "-b:a", "192k"]
        case "webm": return ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-c:a", "libopus", "-b:a", "128k"]
        case "avi": return ["-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame", "-q:a", "3"]
        case "wmv": return ["-c:v", "wmv2", "-b:v", "4M", "-c:a", "wmav2", "-b:a", "192k"]
        case "gif":
            return ["-vf", "fps=12,scale='min(640,iw)':-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse",
                    "-loop", "0", "-an"]
        default: return []
        }
    }

    static func audioArgs(_ ext: String) -> [String] {
        let codec: [String]
        switch ext {
        case "mp3": codec = ["-c:a", "libmp3lame", "-q:a", "2"]
        case "m4a", "m4r": codec = ["-c:a", "aac", "-b:a", "256k"]
        case "aac": codec = ["-c:a", "aac", "-b:a", "256k", "-f", "adts"]
        case "wav": codec = ["-c:a", "pcm_s16le"]
        case "flac": codec = ["-c:a", "flac"]
        case "ogg": codec = ["-c:a", "vorbis", "-strict", "-2", "-ac", "2", "-q:a", "5"]
        case "opus": codec = ["-c:a", "libopus", "-b:a", "160k"]
        case "aiff", "aif": codec = ["-c:a", "pcm_s16be"]
        case "wma": codec = ["-c:a", "wmav2", "-b:a", "192k"]
        default: codec = []
        }
        return ["-vn", "-map_metadata", "0"] + codec
    }

    static let audioExts: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "aiff", "wma"]

    static func convert(_ src: URL, to ext: String) async throws -> URL {
        if audioExts.contains(ext), Engines.has(.ffmpeg), !(try await probe(src).hasAudio) {
            throw FlipdialError("\(src.lastPathComponent) has no sound to extract")
        }
        let out = Output.url(for: src, ext: ext)
        if Engines.has(.ffmpeg) {
            let args = audioExts.contains(ext) ? audioArgs(ext) : videoArgs(ext)
            try await ffmpeg(["-i", src.path] + args + [out.path])
        } else {
            try await convertWithoutFFmpeg(src, ext: ext, out: out)
        }
        return out
    }

    static func canConvertWithoutFFmpeg(_ src: URL, to ext: String) -> Bool {
        let coreAudioIn: Set<String> = ["mp3", "m4a", "wav", "aiff", "aif", "flac", "caf", "aac", "mp4", "mov", "m4v"]
        if ["wav", "aiff", "m4a", "flac", "aac"].contains(ext) { return coreAudioIn.contains(src.ext) }
        if ["mp4", "mov", "m4v"].contains(ext) { return ["mp4", "mov", "m4v"].contains(src.ext) }
        return false
    }

    /// Built-in macOS encoders: afconvert for audio, avconvert for QuickTime-family video.
    private static func convertWithoutFFmpeg(_ src: URL, ext: String, out: URL) async throws {
        guard canConvertWithoutFFmpeg(src, to: ext) else { _ = try Engines.require(.ffmpeg); return }
        switch ext {
        case "wav": try await Shell.run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16", src.path, out.path])
        case "aiff": try await Shell.run("/usr/bin/afconvert", ["-f", "AIFF", "-d", "BEI16", src.path, out.path])
        case "m4a": try await Shell.run("/usr/bin/afconvert", ["-f", "m4af", "-d", "aac", "-b", "256000", src.path, out.path])
        case "aac": try await Shell.run("/usr/bin/afconvert", ["-f", "adts", "-d", "aac", "-b", "256000", src.path, out.path])
        case "flac": try await Shell.run("/usr/bin/afconvert", ["-f", "flac", "-d", "flac", src.path, out.path])
        default:
            try await Shell.run("/usr/bin/avconvert", ["--preset", "PresetHighestQuality", "--source", src.path,
                                                       "--output", out.path, "--replace"])
        }
    }

    // MARK: Tools

    private static func run(_ src: URL, suffix: String, ext: String? = nil, _ args: [String],
                            preInput: [String] = []) async throws -> URL {
        let out = Output.url(for: src, ext: ext ?? src.ext, suffix: suffix)
        try await ffmpeg(preInput + ["-i", src.path] + args + [out.path])
        return out
    }

    static func compressVideo(_ src: URL) async throws -> URL {
        try await run(src, suffix: " (compressed)", ext: "mp4",
                      ["-c:v", "libx264", "-preset", "slow", "-crf", "28", "-pix_fmt", "yuv420p", "-vf", evenSize,
                       "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart"])
    }

    static func scaleVideo(_ src: URL, height: Int) async throws -> URL {
        try await run(src, suffix: " (\(height)p)", ext: "mp4",
                      ["-vf", "scale=-2:'min(\(height),ih)'", "-c:v", "libx264", "-crf", "21", "-pix_fmt", "yuv420p",
                       "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"])
    }

    static func mute(_ src: URL) async throws -> URL {
        try await run(src, suffix: " (muted)", ["-an", "-c:v", "copy"])
    }

    static func rotateVideo(_ src: URL) async throws -> URL {
        try await run(src, suffix: " (rotated)", ext: "mp4",
                      ["-vf", "transpose=1", "-c:v", "libx264", "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "copy"])
    }

    /// Crops to a rectangle in pixel coordinates (origin top-left).
    static func cropVideo(_ src: URL, rect: CGRect) async throws -> URL {
        let w = Int(rect.width) / 2 * 2, h = Int(rect.height) / 2 * 2
        return try await run(src, suffix: " (cropped)", ext: "mp4",
                             ["-vf", "crop=\(w):\(h):\(Int(rect.minX)):\(Int(rect.minY))", "-c:v", "libx264", "-crf", "20",
                              "-pix_fmt", "yuv420p", "-c:a", "copy", "-movflags", "+faststart"])
    }

    static func cropSquareVideo(_ src: URL) async throws -> URL {
        try await run(src, suffix: " (square)", ext: "mp4",
                      ["-vf", "crop='min(iw,ih)':'min(iw,ih)',\(evenSize)", "-c:v", "libx264", "-crf", "20",
                       "-pix_fmt", "yuv420p", "-c:a", "copy"])
    }

    static func speedVideo(_ src: URL, factor: Double) async throws -> URL {
        let hasAudio = (try? await probe(src).hasAudio) ?? false
        var args = ["-filter_complex", "[0:v]setpts=PTS/\(factor)[v]" + (hasAudio ? ";[0:a]atempo=\(factor)[a]" : ""), "-map", "[v]"]
        if hasAudio { args += ["-map", "[a]", "-c:a", "aac", "-b:a", "192k"] }
        return try await run(src, suffix: " (\(formatFactor(factor))x)", ext: "mp4",
                             args + ["-c:v", "libx264", "-crf", "20", "-pix_fmt", "yuv420p", "-movflags", "+faststart"])
    }

    static func snapshot(_ src: URL) async throws -> URL {
        let out = Output.url(for: src, ext: "jpg", suffix: " (frame)")
        let length = (try? await duration(of: src)) ?? 0
        try await ffmpeg(["-ss", String(format: "%.2f", min(1, length / 2)), "-i", src.path,
                          "-frames:v", "1", "-q:v", "2", out.path])
        return out
    }

    static func trim(_ src: URL, start: Double, end: Double?) async throws -> URL {
        var timing = ["-ss", String(start)]
        if let end { timing += ["-to", String(end)] }
        let isAudio = FileKind.kinds(of: src).contains(.audio)
        let codec = isAudio ? audioArgs(src.ext) : videoArgs(src.ext.isEmpty ? "mp4" : src.ext)
        return try await run(src, suffix: " (trimmed)", codec, preInput: timing)
    }

    /// Joins clips end to end, re-encoding so mismatched sources still work.
    static func merge(_ urls: [URL]) async throws -> URL {
        guard let first = urls.first else { throw FlipdialError("Nothing to merge") }
        let isAudio = urls.allSatisfy { FileKind.kinds(of: $0).contains(.audio) }
        let out = Output.url(for: first, ext: isAudio ? first.ext : "mp4", suffix: " (merged)")
        var args: [String] = []
        for url in urls { args += ["-i", url.path] }
        if isAudio {
            let inputs = urls.indices.map { "[\($0):a]" }.joined()
            args += ["-filter_complex", "\(inputs)concat=n=\(urls.count):v=0:a=1[a]", "-map", "[a]"] + audioArgs(first.ext)
        } else {
            // Normalise every clip to 1080p/30fps so differing sources can be concatenated; clips
            // without sound get a silent track so the audio stays in sync.
            let size = "scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30"
            var filter = ""
            for (i, url) in urls.enumerated() {
                let info = try await probe(url)
                filter += "[\(i):v]\(size)[v\(i)];"
                filter += info.hasAudio
                    ? "[\(i):a]aresample=48000,aformat=channel_layouts=stereo[a\(i)];"
                    : "anullsrc=r=48000:cl=stereo,atrim=duration=\(max(info.duration, 0.1))[a\(i)];"
            }
            filter += urls.indices.map { "[v\($0)][a\($0)]" }.joined() + "concat=n=\(urls.count):v=1:a=1[v][a]"
            args += ["-filter_complex", filter, "-map", "[v]", "-map", "[a]",
                     "-c:v", "libx264", "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k"]
        }
        try await ffmpeg(args + [out.path])
        return out
    }

    static func compressAudio(_ src: URL) async throws -> URL {
        try await run(src, suffix: " (compressed)", ext: "mp3", ["-vn", "-c:a", "libmp3lame", "-b:a", "128k"])
    }

    static func normalize(_ src: URL) async throws -> URL {
        try await run(src, suffix: " (normalized)", ["-af", "loudnorm=I=-16:TP=-1.5:LRA=11"] + audioArgs(src.ext))
    }

    static func mono(_ src: URL) async throws -> URL {
        try await run(src, suffix: " (mono)", ["-ac", "1"] + audioArgs(src.ext))
    }

    static func speedAudio(_ src: URL, factor: Double) async throws -> URL {
        try await run(src, suffix: " (\(formatFactor(factor))x)", ["-af", "atempo=\(factor)"] + audioArgs(src.ext))
    }

    static func fade(_ src: URL) async throws -> URL {
        let length = try await duration(of: src)
        let fade = min(3, length / 4)
        return try await run(src, suffix: " (faded)",
                             ["-af", "afade=t=in:d=\(fade),afade=t=out:st=\(length - fade):d=\(fade)"] + audioArgs(src.ext))
    }

    static func removeSilence(_ src: URL) async throws -> URL {
        try await run(src, suffix: " (no silence)",
                      ["-af", "silenceremove=start_periods=1:start_threshold=-50dB:stop_periods=-1:stop_duration=0.6:stop_threshold=-50dB"]
                      + audioArgs(src.ext))
    }

    private static func formatFactor(_ f: Double) -> String {
        f == f.rounded() ? String(Int(f)) : String(f)
    }
}
