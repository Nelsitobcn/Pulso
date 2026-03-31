import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var authService: AuthService
    @AppStorage("pulso_audio_latency") private var audioLatency: Double = 0.01
    @AppStorage("pulso_auto_analyze") private var autoAnalyze: Bool = true
    @AppStorage("pulso_crossfade_curve") private var crossfadeCurve: String = "linear"

    var body: some View {
        TabView {
            AudioSettingsTab(latency: $audioLatency, curve: $crossfadeCurve)
                .tabItem { Label("Audio", systemImage: "waveform") }

            LibrarySettingsTab(autoAnalyze: $autoAnalyze)
                .tabItem { Label("Biblioteca", systemImage: "music.note.list") }

            DJProfileTab()
                .tabItem { Label("Perfil", systemImage: "person.circle") }
        }
        .frame(width: 480, height: 320)
        .padding()
    }
}

struct AudioSettingsTab: View {
    @Binding var latency: Double
    @Binding var curve: String

    var body: some View {
        Form {
            Section("Rendimiento") {
                HStack {
                    Text("Latencia de audio")
                    Spacer()
                    Slider(value: $latency, in: 0.005...0.05)
                        .frame(width: 150)
                    Text("\(Int(latency * 1000)) ms")
                        .frame(width: 40)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Crossfader") {
                Picker("Curva del crossfader", selection: $curve) {
                    Text("Lineal").tag("linear")
                    Text("Tipo S (suave)").tag("scurve")
                    Text("Corte (scratch)").tag("cut")
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
    }
}

struct LibrarySettingsTab: View {
    @Binding var autoAnalyze: Bool

    var body: some View {
        Form {
            Section("Importación") {
                Toggle("Analizar BPM y key automáticamente al importar", isOn: $autoAnalyze)
                Text("El análisis puede tardar unos segundos por pista pero mejora la experiencia de mezcla.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct DJProfileTab: View {
    @EnvironmentObject var authService: AuthService

    var body: some View {
        Form {
            Section("Tu perfil") {
                TextField("Nombre de DJ", text: $authService.djName)
            }

            Section("Plan") {
                LabeledContent("Plan actual", value: authService.plan.displayName)
                Text("Las suscripciones Pro y Pro+ estarán disponibles próximamente en el App Store.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
