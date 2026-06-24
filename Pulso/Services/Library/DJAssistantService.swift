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

    struct Suggestion: Identifiable {
        let id = UUID()
        let track: Track
        let reason: String
    }

    @Published var suggestions: [Suggestion] = []
    @Published var isThinking = false
    @Published var errorText: String?

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
