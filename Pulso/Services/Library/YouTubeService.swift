import Foundation
import AVFoundation

/// Descarga audio de YouTube vía `yt-dlp` y lo convierte en pistas locales analizables.
///
/// ⚠️ SOLO macOS. iOS no permite ejecutar binarios externos (`Process`), así que en iPad
/// esta clase reporta `unsupportedPlatform`. El puente iPad (servidor en el Mac Studio) es
/// trabajo futuro — ver ROADMAP A2.
///
/// Decisiones de seguridad (auditoría Fugu/DeepSeek 23-jun-2026):
/// - Argumentos a yt-dlp SIEMPRE como array (`Process.arguments`), NUNCA string interpolado
///   → evita inyección de comandos desde títulos maliciosos.
/// - Descarga el archivo COMPLETO antes de cargar (no URL de streaming, que expira en ~6h).
/// - Caché con límite de tamaño + evicción LRU → no llena el disco.
@MainActor
final class YouTubeService: ObservableObject {

    enum YouTubeError: LocalizedError {
        case unsupportedPlatform
        case ytdlpNotFound
        case downloadFailed(String)
        case noResult

        var errorDescription: String? {
            switch self {
            case .unsupportedPlatform: return "La descarga de YouTube solo está disponible en Mac."
            case .ytdlpNotFound:       return "No se encontró yt-dlp. Instálalo con: brew install yt-dlp"
            case .downloadFailed(let m): return "Error al descargar: \(m)"
            case .noResult:            return "No se encontró ningún resultado."
            }
        }
    }

    @Published var isDownloading = false
    @Published var statusText = ""
    @Published var isPreviewing = false
    @Published var previewTitle = ""
    private var previewPlayer: AVPlayer?

    /// Tamaño máximo de la caché de audio descargado (2 GB).
    private let maxCacheBytes: Int64 = 2 * 1024 * 1024 * 1024

    /// Directorio de caché: ~/Music/PulsoCache (macOS).
    private var cacheDir: URL {
        let base = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("PulsoCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - API pública

    /// Resultado de un stream en vivo: URL directa (caduca ~6h) + metadatos para mostrar.
    struct StreamResult {
        let url: URL
        let title: String
        let artist: String
        let durationSeconds: TimeInterval
    }

    /// PLAY EN VIVO — busca en YouTube y devuelve la URL de stream directa (sin descargar).
    /// Reproduce al instante con AVPlayer. ⚠️ La URL caduca en ~6h: para sesiones largas usar
    /// `download`. Ideal para previsualizar o lanzar un tema rápido.
    func streamURL(query: String) async throws -> StreamResult {
        #if !os(macOS)
        throw YouTubeError.unsupportedPlatform
        #else
        guard let ytdlp = Self.ytdlpPath() else { throw YouTubeError.ytdlpNotFound }
        isDownloading = true
        statusText = "Buscando…"
        defer { isDownloading = false }

        let target = Self.isYouTubeURL(query) ? query : "ytsearch1:\(query)"
        // Pide URL + título + artista + duración en líneas separadas (--print).
        let args = [
            target, "-f", "bestaudio", "--no-playlist", "--no-warnings", "--no-update",
            "--print", "urls",
            "--print", "title",
            "--print", "%(artist,uploader|)s",
            "--print", "%(duration)s"
        ]
        let output = try await Self.run(executable: ytdlp, arguments: args)
        let lines = output.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let urlLine = lines.first(where: { $0.hasPrefix("http") }),
              let url = URL(string: urlLine) else { throw YouTubeError.noResult }

        // Tras la URL vienen title, artist, duration (en ese orden).
        let after = lines.drop(while: { !$0.hasPrefix("http") }).dropFirst()
        let meta = Array(after)
        let title = meta.first ?? query
        let artist = meta.count > 1 && !meta[1].isEmpty ? meta[1] : "YouTube"
        let dur = meta.count > 2 ? (Double(meta[2]) ?? 0) : 0

        statusText = "En vivo"
        return StreamResult(url: url, title: title, artist: artist, durationSeconds: dur)
        #endif
    }

    /// Reproduce un stream de YouTube en vivo con AVPlayer (preescucha en auriculares).
    /// No pasa por el motor de DJ (sin EQ/SYNC) — es solo previsualización.
    func preview(query: String) async throws {
        stopPreview()
        let result = try await streamURL(query: query)
        let player = AVPlayer(url: result.url)
        previewPlayer = player
        previewTitle = "\(result.artist) — \(result.title)"
        isPreviewing = true
        player.play()
    }

    func stopPreview() {
        previewPlayer?.pause()
        previewPlayer = nil
        isPreviewing = false
        previewTitle = ""
    }

    /// Busca en YouTube por texto libre (o acepta una URL directa) y descarga el primer
    /// resultado como `.m4a` en la caché. Devuelve la URL local del archivo descargado.
    func download(query: String) async throws -> URL {
        #if !os(macOS)
        throw YouTubeError.unsupportedPlatform
        #else
        guard let ytdlp = Self.ytdlpPath() else { throw YouTubeError.ytdlpNotFound }

        isDownloading = true
        statusText = "Buscando en YouTube…"
        defer { isDownloading = false }

        // Si es una URL de YouTube se usa tal cual; si es texto, se busca el primer resultado.
        let target = Self.isYouTubeURL(query) ? query : "ytsearch1:\(query)"

        // Plantilla de salida: "Artista - Título [ID]" → el [ID] mantiene la idempotencia
        // de caché y el "Artista - Título" hace que Track.from(url:) muestre el nombre real
        // en la biblioteca (en vez del ID crudo de YouTube).
        let outTemplate = cacheDir.appendingPathComponent("%(artist,uploader|)s - %(title)s [%(id)s].%(ext)s").path

        // ⚠️ Args como ARRAY — el query nunca se interpola en un string de shell.
        var args = [
            target,
            "-x", "--audio-format", "m4a", "--audio-quality", "0",
            "--no-playlist",
            "-o", outTemplate,
            "--print", "after_move:filepath",   // imprime la ruta final del archivo
            "--no-warnings", "--no-update"
        ]
        // yt-dlp llama a ffmpeg por nombre. Una app GUI NO hereda el PATH de Homebrew,
        // así que se le indica la ubicación exacta de ffmpeg para que el postproceso (-x) funcione.
        if let ffmpegDir = Self.homebrewBinDir() {
            args.append(contentsOf: ["--ffmpeg-location", ffmpegDir])
        }

        statusText = "Descargando audio…"
        let output = try await Self.run(executable: ytdlp, arguments: args)

        // yt-dlp imprime la ruta final del archivo (gracias a --print after_move:filepath).
        let path = output
            .split(separator: "\n")
            .map(String.init)
            .last(where: { $0.hasSuffix(".m4a") })?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let path, FileManager.default.fileExists(atPath: path) else {
            throw YouTubeError.noResult
        }

        evictCacheIfNeeded()
        statusText = "Listo"
        return URL(fileURLWithPath: path)
        #endif
    }

    // MARK: - Implementación macOS

    #if os(macOS)
    /// Localiza el binario yt-dlp en las rutas típicas de Homebrew.
    private static func ytdlpPath() -> String? {
        let candidates = ["/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func isYouTubeURL(_ s: String) -> Bool {
        let l = s.lowercased()
        return l.hasPrefix("http") && (l.contains("youtube.com") || l.contains("youtu.be"))
    }

    /// Directorio bin de Homebrew donde viven ffmpeg/deno (Apple Silicon o Intel).
    private static func homebrewBinDir() -> String? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin"] {
            if FileManager.default.isExecutableFile(atPath: dir + "/ffmpeg") { return dir }
        }
        return nil
    }

    /// Ejecuta un proceso y devuelve su stdout. Lanza si el exit code ≠ 0.
    private static func run(executable: String, arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            // Una app GUI hereda un PATH minimal (sin Homebrew). yt-dlp necesita encontrar
            // `deno` (resuelve los retos JS de YouTube) y `ffmpeg`. Se inyecta el PATH completo.
            var env = ProcessInfo.processInfo.environment
            let extraPaths = "/opt/homebrew/bin:/usr/local/bin"
            env["PATH"] = extraPaths + ":" + (env["PATH"] ?? "/usr/bin:/bin")
            process.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            process.terminationHandler = { proc in
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: outData, encoding: .utf8) ?? ""
                let err = String(data: errData, encoding: .utf8) ?? ""

                if proc.terminationStatus == 0 {
                    continuation.resume(returning: out)
                } else {
                    continuation.resume(throwing: YouTubeError.downloadFailed(err.isEmpty ? out : err))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: YouTubeError.downloadFailed(error.localizedDescription))
            }
        }
    }

    /// Evicción LRU: si la caché supera el límite, borra los archivos más antiguos
    /// (por fecha de último acceso) hasta volver bajo el umbral.
    private func evictCacheIfNeeded() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey]
        guard let files = try? fm.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: keys, options: .skipsHiddenFiles
        ) else { return }

        var entries = files.compactMap { url -> (url: URL, size: Int64, atime: Date)? in
            guard let v = try? url.resourceValues(forKeys: Set(keys)),
                  let size = v.fileSize, let atime = v.contentAccessDate else { return nil }
            return (url, Int64(size), atime)
        }

        var total = entries.reduce(Int64(0)) { $0 + $1.size }
        guard total > maxCacheBytes else { return }

        // Más antiguos primero (LRU).
        entries.sort { $0.atime < $1.atime }
        for entry in entries {
            if total <= maxCacheBytes { break }
            try? fm.removeItem(at: entry.url)
            total -= entry.size
        }
    }
    #endif
}
