import Foundation

/// "Mauri-Bot": asistente de IA local (Ollama) que sugiere el orden de las próximas
/// canciones de un set, razonando sobre compatibilidad armónica (Camelot), BPM y energía.
///
/// Usa Ollama en localhost (modelo local, gratis, sin enviar datos a la nube). Si Ollama
/// no responde, cae a un ranking determinista basado en `LibraryService.suggestions`.
///
/// ⚠️ Solo macOS por ahora (Ollama corre en el Mac). En iPad necesitaría apuntar a la IP
/// del Mac Studio en la red local — trabajo futuro.
@MainActor
final class DJAssistantService: ObservableObject {

    /// Origen de una sugerencia: de la biblioteca local o de las tendencias globales.
    enum Origin: Equatable {
        case local
        /// De tendencias y NO está en la biblioteca → hay que buscarla en YouTube.
        /// Lleva el query listo para el panel de búsqueda.
        case trending(youtubeQuery: String)
    }

    struct Suggestion: Identifiable {
        let id = UUID()
        let track: Track
        let reason: String
        var origin: Origin = .local
    }

    /// Un tema de tendencia (fichero curado `trending.json`, extensible a scraper).
    struct TrendingTrack: Codable {
        let title: String
        let artist: String
        let genre: String
        let bpm: Double
        let camelot: String
        let energy: Double
    }

    /// Tendencias globales cargadas del fichero curado. Vacío si no se pudo leer.
    private(set) var trending: [TrendingTrack] = []

    /// Carga `trending.json` del bundle (una vez). Seguro si falta: deja la lista vacía.
    func loadTrendingIfNeeded() {
        guard trending.isEmpty,
              let url = Bundle.main.url(forResource: "trending", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return }
        struct File: Codable { let tracks: [TrendingTrack] }
        trending = (try? JSONDecoder().decode(File.self, from: data))?.tracks ?? []
    }

    @Published var suggestions: [Suggestion] = []
    @Published var isThinking = false
    @Published var errorText: String?

    /// Cola de la sesión generada al inicio (orden ideal de reproducción para el mood elegido).
    @Published var sessionQueue: [Suggestion] = []

    private let ollamaURL = URL(string: "http://localhost:11434/api/generate")!
    private let model = "qwen3-coder:30b-a3b-q4_K_M"

    /// Genera una cola sugerida a partir de la canción actual y la biblioteca disponible.
    func suggest(current: Track, library: [Track]) async {
        isThinking = true
        errorText = nil
        defer { isThinking = false }

        // Candidatos pre-filtrados por compatibilidad (no mandar toda la biblioteca a la IA).
        let candidates = rankCandidates(current: current, pool: library)
        guard !candidates.isEmpty else {
            suggestions = []
            errorText = "No hay canciones compatibles en la biblioteca."
            return
        }

        // Intentar razonamiento con Ollama; si falla, usar el ranking determinista.
        if let aiOrder = await askOllama(current: current, candidates: candidates) {
            suggestions = aiOrder
        } else {
            suggestions = candidates.prefix(5).map {
                Suggestion(track: $0, reason: reasonFor(current: current, next: $0))
            }
        }
    }

    /// Sugerencia HÍBRIDA: mezcla la biblioteca local con las tendencias globales curadas.
    /// - Los temas locales compatibles se ordenan por el score de siempre (Camelot+BPM+energía).
    /// - Los temas de tendencia compatibles con el actual que NO están en la biblioteca se
    ///   añaden marcados como `.trending` con un query de YouTube listo para el panel #3.
    /// El resultado intercala ambos para que el DJ vea "lo que tiene" y "lo que suena fuera".
    func suggestHybrid(current: Track, library: [Track]) async {
        isThinking = true
        errorText = nil
        defer { isThinking = false }
        loadTrendingIfNeeded()

        // 1) Locales (reusa la lógica existente).
        let localRanked = rankCandidates(current: current, pool: library)
        let localSug = localRanked.prefix(5).map {
            Suggestion(track: $0, reason: reasonFor(current: current, next: $0), origin: .local)
        }

        // 2) Tendencias compatibles que NO están ya en la biblioteca.
        let libraryKeys = Set(library.map { "\($0.title.lowercased())|\($0.artist.lowercased())" })
        let curBPM = (current.bpm ?? 0) * 1.0
        let trendingSug: [Suggestion] = trending.compactMap { t in
            let key = "\(t.title.lowercased())|\(t.artist.lowercased())"
            if libraryKeys.contains(key) { return nil }   // ya la tienes local → no duplicar
            // Filtro de compatibilidad ligero: BPM dentro de ±12% (incluye doble/mitad) o Camelot igual.
            let bpmOK = curBPM <= 0 || bpmCompatible(curBPM, t.bpm)
            let keyOK = current.key?.rawValue == t.camelot
            guard bpmOK || keyOK else { return nil }
            // Track "fantasma" (no descargado): sirve para mostrar título/artista/bpm en la UI.
            let ghost = Track(title: t.title, artist: t.artist,
                              url: URL(fileURLWithPath: "/trending/\(t.title)"),
                              bpm: t.bpm, key: MusicalKey(rawValue: t.camelot), genre: t.genre)
            let reason = "🔥 Tendencia (\(t.genre)) · \(Int(t.bpm)) BPM \(t.camelot) — búscala en YouTube"
            return Suggestion(track: ghost, reason: reason,
                              origin: .trending(youtubeQuery: "\(t.artist) \(t.title)"))
        }

        // 3) Intercalar: primero 3 locales, luego tendencias, luego el resto local.
        var mixed: [Suggestion] = []
        mixed.append(contentsOf: localSug.prefix(3))
        mixed.append(contentsOf: trendingSug.prefix(3))
        mixed.append(contentsOf: localSug.dropFirst(3))

        if mixed.isEmpty {
            errorText = "No hay canciones compatibles (ni local ni en tendencias)."
        }
        suggestions = mixed
    }

    /// BPM compatible: exacto (≤8%) o en relación doble/mitad (≤8%).
    private func bpmCompatible(_ a: Double, _ b: Double) -> Bool {
        guard a > 0, b > 0 else { return false }
        let ratios = [1.0, 2.0, 0.5]
        return ratios.contains { abs(a - b * $0) / a <= 0.08 }
    }

    /// Arma la cola de una SESIÓN a partir de un mood/estilo (ej. "salsa", "techno peak time",
    /// "calentamiento chill") usando toda la biblioteca. La IA ordena por flujo de energía y
    /// compatibilidad armónica/BPM. Si Ollama falla, ordena por energía ascendente.
    func buildSession(mood: String, library: [Track]) async {
        isThinking = true
        errorText = nil
        defer { isThinking = false }

        guard !library.isEmpty else {
            sessionQueue = []
            errorText = "La biblioteca está vacía. Baja o importa canciones primero."
            return
        }

        if let aiOrder = await askOllamaSession(mood: mood, pool: library) {
            sessionQueue = aiOrder
        } else {
            // Fallback: ordenar por energía ascendente (warm-up → peak).
            sessionQueue = library
                .sorted { ($0.energy ?? 0) < ($1.energy ?? 0) }
                .prefix(10)
                .map { Suggestion(track: $0, reason: "Orden por energía") }
        }
    }

    private func askOllamaSession(mood: String, pool: [Track]) async -> [Suggestion]? {
        let top = Array(pool.prefix(30))   // límite razonable para el prompt
        let list = top.enumerated().map { i, t in
            "\(i): \"\(t.title)\" — \(t.artist) — \(t.bpm.map { String(format: "%.0f BPM", $0) } ?? "?BPM") — key \(t.key?.rawValue ?? "?")"
        }.joined(separator: "\n")

        let prompt = """
        Eres un DJ experto montando el SET de esta noche. El estilo/mood pedido es: "\(mood)".

        Biblioteca disponible (índice: tema):
        \(list)

        Selecciona y ORDENA hasta 10 canciones que encajen con "\(mood)", formando una progresión
        coherente: empieza más suave/baja energía y sube hacia el clímax, encadenando por
        compatibilidad armónica (Camelot) y BPM cercano. Si una canción no pega con el mood,
        descártala. Devuelve SOLO un array JSON, sin texto extra:
        [{"i": <índice>, "reason": "<motivo corto en español>"}]
        """

        let body: [String: Any] = [
            "model": model, "prompt": prompt, "stream": false,
            "format": "json", "options": ["temperature": 0.5]
        ]
        do {
            var req = URLRequest(url: ollamaURL)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.timeoutInterval = 90
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let responseStr = outer["response"] as? String,
                  let innerData = responseStr.data(using: .utf8) else { return nil }
            let parsed = parseAIArray(innerData)
            guard !parsed.isEmpty else { return nil }
            return parsed.compactMap { item in
                guard item.i >= 0, item.i < top.count else { return nil }
                return Suggestion(track: top[item.i], reason: item.reason)
            }
        } catch {
            return nil
        }
    }

    // MARK: - Ranking determinista (Camelot + BPM + energía)

    private func rankCandidates(current: Track, pool: [Track]) -> [Track] {
        pool.filter { $0.id != current.id }
            .sorted { a, b in
                score(current: current, next: a) > score(current: current, next: b)
            }
    }

    private func score(current: Track, next: Track) -> Double {
        var s = 0.0
        // Armonía Camelot: compatible suma fuerte.
        if let ck = current.key, let nk = next.key {
            if ck == nk { s += 3 }
            else if nk.isCompatible(with: ck) { s += 2 }
        }
        // BPM cercano (incluyendo doble/mitad).
        if let cb = current.bpm, let nb = next.bpm {
            let diffs = [nb, nb * 2, nb / 2].map { abs($0 - cb) / max(cb, 1) }
            if let best = diffs.min() {
                if best <= 0.03 { s += 3 }
                else if best <= 0.08 { s += 1.5 }
            }
        }
        // Energía progresiva (subir energía suave).
        if let ce = current.energy, let ne = next.energy {
            let delta = ne - ce
            if delta >= 0 && delta <= 0.2 { s += 1 }
        }
        return s
    }

    private func reasonFor(current: Track, next: Track) -> String {
        var parts: [String] = []
        if let ck = current.key, let nk = next.key {
            if ck == nk { parts.append("misma tonalidad (\(nk.rawValue))") }
            else if nk.isCompatible(with: ck) { parts.append("armónica con \(ck.rawValue)→\(nk.rawValue)") }
        }
        if let cb = current.bpm, let nb = next.bpm {
            parts.append(String(format: "%.0f→%.0f BPM", cb, nb))
        }
        return parts.isEmpty ? "Compatible" : parts.joined(separator: ", ")
    }

    // MARK: - Ollama

    private func askOllama(current: Track, candidates: [Track]) async -> [Suggestion]? {
        // Lista numerada de candidatos para que la IA elija por índice.
        let top = Array(candidates.prefix(12))
        let list = top.enumerated().map { i, t in
            "\(i): \"\(t.title)\" — \(t.artist) — \(t.bpm.map { String(format: "%.0f BPM", $0) } ?? "?BPM") — key \(t.key?.rawValue ?? "?")"
        }.joined(separator: "\n")

        let prompt = """
        Eres un DJ experto haciendo la transición de un set. Suena ahora:
        "\(current.title)" — \(current.artist) — \(current.bpm.map { String(format: "%.0f BPM", $0) } ?? "?BPM") — key \(current.key?.rawValue ?? "?").

        Estos son los candidatos para las próximas canciones (índice: tema):
        \(list)

        Elige las 5 mejores SIGUIENTES en el orden ideal de mezcla, priorizando compatibilidad
        armónica (rueda Camelot: misma key o ±1, o A↔B mismo número) y BPM cercano, subiendo
        energía gradualmente. Devuelve SOLO un array JSON, sin texto extra, con este formato:
        [{"i": <índice>, "reason": "<motivo corto en español>"}]
        """

        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "stream": false,
            "format": "json",
            "options": ["temperature": 0.4]
        ]

        do {
            var req = URLRequest(url: ollamaURL)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.timeoutInterval = 60

            let (data, _) = try await URLSession.shared.data(for: req)

            // Ollama envuelve la respuesta en {"response": "<json string>"}.
            guard let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let responseStr = outer["response"] as? String,
                  let innerData = responseStr.data(using: .utf8) else { return nil }

            // El JSON pedido puede venir como array directo o envuelto en una clave.
            let parsed = parseAIArray(innerData)
            guard !parsed.isEmpty else { return nil }

            return parsed.compactMap { item in
                guard item.i >= 0, item.i < top.count else { return nil }
                return Suggestion(track: top[item.i], reason: item.reason)
            }
        } catch {
            return nil
        }
    }

    private struct AIPick { let i: Int; let reason: String }

    /// Parsea el JSON de la IA, tolerante a que venga como array directo o envuelto.
    private func parseAIArray(_ data: Data) -> [AIPick] {
        func picks(from array: [[String: Any]]) -> [AIPick] {
            array.compactMap { dict in
                guard let i = dict["i"] as? Int else { return nil }
                let reason = dict["reason"] as? String ?? "Sugerido por la IA"
                return AIPick(i: i, reason: reason)
            }
        }
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return picks(from: arr)
        }
        // Envuelto: {"suggestions": [...]} o similar — coger el primer array de dicts.
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for value in obj.values {
                if let arr = value as? [[String: Any]] { return picks(from: arr) }
            }
        }
        return []
    }
}
