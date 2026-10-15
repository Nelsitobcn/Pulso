import Foundation

// MARK: - Tipos de stem

/// Los 4 stems que produce htdemucs. `melody` corresponde al stem "other" de Demucs
/// (todo lo que no es voz/batería/bajo: sintes, guitarras, pads…).
enum StemType: Int, CaseIterable, Sendable {
    case vocal = 0
    case drums = 1
    case bass = 2
    case melody = 3

    /// Nombre de archivo que escribe demucs-mlx (htdemucs).
    var demucsFileName: String {
        switch self {
        case .vocal:  return "vocals.wav"
        case .drums:  return "drums.wav"
        case .bass:   return "bass.wav"
        case .melody: return "other.wav"
        }
    }

    /// Etiqueta corta para la UI.
    var label: String {
        switch self {
        case .vocal:  return "VOX"
        case .drums:  return "DRM"
        case .bass:   return "BASS"
        case .melody: return "MEL"
        }
    }
}

// MARK: - Almacén de stems en disco

/// Dónde viven los stems separados de cada pista:
/// `~/Library/Application Support/Pulso/Stems/<trackID>/{vocals,drums,bass,other}.wav`
///
/// Deliberadamente FUERA de ~/Music/PulsoCache: la evicción LRU de 2 GB de YouTubeService
/// borraría los stems (que cuestan segundos de GPU regenerar). Aquí conviven con library.json.
/// No se persiste nada en Track: la fuente de verdad es el disco (fileExists), indexado por
/// track.id — así una caché borrada nunca deja rutas colgantes en el JSON.
enum StemStore {
    static func directory(for trackID: UUID) -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return appSupport
            .appendingPathComponent("Pulso", isDirectory: true)
            .appendingPathComponent("Stems", isDirectory: true)
            .appendingPathComponent(trackID.uuidString, isDirectory: true)
    }

    /// URLs de los 4 stems, en orden `StemType.rawValue`, o `nil` si falta alguno.
    static func urls(for trackID: UUID) -> [URL]? {
        let dir = directory(for: trackID)
        let urls = StemType.allCases.map { dir.appendingPathComponent($0.demucsFileName) }
        let fm = FileManager.default
        return urls.allSatisfy { fm.fileExists(atPath: $0.path) } ? urls : nil
    }

    static func available(for trackID: UUID) -> Bool {
        urls(for: trackID) != nil
    }
}

// MARK: - Separador (demucs-mlx vía Process)

/// Separa una pista en 4 stems ejecutando `demucs-mlx` (port MIT de Demucs a MLX,
/// ~73× tiempo real en Apple Silicon). Instalación en el Mac:
///
///     pipx install demucs-mlx        # o: pip3 install --user demucs-mlx
///
/// ⚠️ SOLO macOS (iOS no permite `Process`). Mismas reglas de seguridad que YouTubeService
/// (auditoría Fugu 23-jun-2026): argumentos SIEMPRE como array y PATH inyectado
/// (una app GUI hereda un PATH minimal sin Homebrew ni ~/.local/bin).
actor StemSeparator {
    static let shared = StemSeparator()

    enum StemError: LocalizedError {
        case unsupportedPlatform
        case demucsNotFound
        case ffmpegNotFound
        case separationFailed(String)
        case outputMissing

        var errorDescription: String? {
            switch self {
            case .unsupportedPlatform:
                return "La separación de stems solo está disponible en Mac."
            case .demucsNotFound:
                return "No se encontró demucs-mlx. Instálalo con: pipx install demucs-mlx"
            case .ffmpegNotFound:
                return "No se encontró ffmpeg (necesario para convertir a WAV)."
            case .separationFailed(let m):
                return "Error separando stems: \(m)"
            case .outputMissing:
                return "demucs-mlx terminó pero faltan archivos de stems."
            }
        }
    }

    /// Separa `trackURL` en 4 stems y los deja en `StemStore.directory(for: trackID)`.
    /// Idempotente: si ya existen, no recalcula. Duración típica: 3-10 s por pista (M-series).
    /// - Returns: URLs de los 4 stems en orden `StemType.rawValue`.
    func separate(trackURL: URL, trackID: UUID) async throws -> [URL] {
        #if !os(macOS)
        throw StemError.unsupportedPlatform
        #else
        // Ya separada → reutilizar (los stems son deterministas para el mismo archivo).
        if let existing = StemStore.urls(for: trackID) { return existing }

        guard let demucs = Self.demucsPath() else { throw StemError.demucsNotFound }

        let fm = FileManager.default
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("pulso-stems-\(trackID.uuidString)", isDirectory: true)
        try? fm.removeItem(at: workDir)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        // 1. Entrada SIEMPRE como WAV 44.1k estéreo: garantiza que mlx-audio-io la lea
        //    (los .m4a de YouTube no están garantizados) y que los 4 stems salgan con
        //    formato idéntico y alineado muestra a muestra.
        let inputWav: URL
        if trackURL.pathExtension.lowercased() == "wav" {
            inputWav = trackURL
        } else {
            guard let ffmpeg = Self.ffmpegPath() else { throw StemError.ffmpegNotFound }
            let converted = workDir.appendingPathComponent("input.wav")
            _ = try await Self.run(executable: ffmpeg, arguments: [
                "-y", "-i", trackURL.path,
                "-ac", "2", "-ar", "44100", "-sample_fmt", "s16",
                converted.path
            ])
            inputWav = converted
        }

        // 2. Separación. Salida: <workDir>/htdemucs/<nombre-sin-ext>/{vocals,drums,bass,other}.wav
        // --prefetch-tracks 0 --write-workers 1: el modo multihilo de demucs-mlx 1.4.4
        // crashea con MLX 0.31+ ("There is no Stream(gpu, 1) in current thread") porque
        // evalúa tensores GPU desde un hilo secundario. Con 1 pista no perdemos nada.
        _ = try await Self.run(executable: demucs, arguments: [
            inputWav.path,
            "-n", "htdemucs",
            "-o", workDir.path,
            "--prefetch-tracks", "0",
            "--write-workers", "1"
        ])

        // demucs-mlx escribe en <out>/<nombre>/ directamente (verificado 1.4.4);
        // el Demucs original añade una subcarpeta <modelo>/. Aceptamos ambas.
        let baseName = inputWav.deletingPathExtension().lastPathComponent
        let flatDir = workDir.appendingPathComponent(baseName, isDirectory: true)
        let nestedDir = workDir
            .appendingPathComponent("htdemucs", isDirectory: true)
            .appendingPathComponent(baseName, isDirectory: true)
        let outDir = fm.fileExists(atPath: flatDir.appendingPathComponent(StemType.vocal.demucsFileName).path)
            ? flatDir : nestedDir

        // 3. Mover a la carpeta definitiva indexada por trackID.
        let destDir = StemStore.directory(for: trackID)
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        for stem in StemType.allCases {
            let src = outDir.appendingPathComponent(stem.demucsFileName)
            guard fm.fileExists(atPath: src.path) else { throw StemError.outputMissing }
            let dst = destDir.appendingPathComponent(stem.demucsFileName)
            try? fm.removeItem(at: dst)
            try fm.moveItem(at: src, to: dst)
        }

        guard let urls = StemStore.urls(for: trackID) else { throw StemError.outputMissing }
        return urls
        #endif
    }

    // MARK: - Localización de binarios (macOS)

    #if os(macOS)
    /// Localiza demucs-mlx. Override manual con la env var PULSO_DEMUCS_PATH.
    private static func demucsPath() -> String? {
        if let override = ProcessInfo.processInfo.environment["PULSO_DEMUCS_PATH"],
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/demucs-mlx",      // pipx / pip --user
            "/opt/homebrew/bin/demucs-mlx",
            "/usr/local/bin/demucs-mlx",
            "\(home)/Library/Python/3.12/bin/demucs-mlx",
            "\(home)/Library/Python/3.11/bin/demucs-mlx"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func ffmpegPath() -> String? {
        let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Ejecuta un proceso y devuelve su stdout. Lanza si exit code ≠ 0.
    /// (Mismo patrón que YouTubeService.run — PATH inyectado para apps GUI.)
    private static func run(executable: String, arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            var env = ProcessInfo.processInfo.environment
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let extraPaths = "/opt/homebrew/bin:/usr/local/bin:\(home)/.local/bin"
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
                    continuation.resume(throwing: StemError.separationFailed(err.isEmpty ? out : err))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: StemError.separationFailed(error.localizedDescription))
            }
        }
    }
    #endif
}
