import FocusCore
import SwiftUI

/// Work days and hours, distraction domains, app bundle identifiers, the iPhone and developer mode. Save writes them to disk.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var draft = Settings()
    @State private var domains = ""
    @State private var apps = ""

    var body: some View {
        Form {
            Section("Work") {
                HStack(spacing: Metrics.row) {
                    ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in  // Calendar weekdays, Monday first.
                        Chip(text: Calendar.current.shortWeekdaySymbols[day - 1], on: draft.workDays.contains(day)) { draft.workDays.formSymmetricDifference([day]) }
                    }
                }
                Picker("Starts", selection: startBinding) { ForEach(0..<24, id: \.self) { Text(hour($0)).tag($0 * 60) } }
                Picker("Ends", selection: $draft.workEnd) { ForEach(min(draft.workStart / 60 + 1, 24)...24, id: \.self) { Text(hour($0)).tag($0 * 60) } }
            }
            Section { lineEditor($domains, height: 130) } header: { Text("Distractions") } footer: { Text("Domains, one per line. A subdomain counts.") }
            Section { lineEditor($apps, height: 60) } header: { Text("Apps") } footer: { Text("Bundle identifiers, one per line.") }
            Section {
                HStack {
                    Text(model.settings.iPhoneName ?? "Not found yet").foregroundStyle(model.settings.iPhone == nil ? .secondary : .primary)
                    Spacer()
                    Button(model.findingPhone ? "Looking…" : model.settings.iPhone == nil ? "Find" : "Find again") { model.findPhone() }
                        .disabled(model.findingPhone || !PhoneSensor.authorized)
                }
            } header: { Text("iPhone") } footer: { Text("Unlock it and hold it next to the Mac. Only this iPhone counts as phone use.") }
            Section {
                HStack {
                    // Applies at once, without Save, like a switch.
                    Toggle("Developer mode", isOn: Binding(get: { draft.developerMode == true }, set: { on in
                        (draft.developerMode, model.settings.developerMode) = (on, on)
                        model.saveSettings()
                    }))
                    Spacer()
                    Button("Show saved") { model.revealFalseAlarms() }
                }
            } header: { Text("Developer") } footer: {
                Text("Keeps each check-in you mark as a false alarm, with its camera frame, screen and sensor log, to improve detection with later. On this Mac only.")
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack { Spacer(); Button("Save") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }.padding(Metrics.card)
        }
        .frame(width: 460, height: 870)
        .onAppear { draft = model.settings; (domains, apps) = (model.settings.domains.joined(separator: "\n"), model.settings.apps.joined(separator: "\n")) }
    }

    /// A text box in the system's text-field style, with the same font and inset as the rest of the window.
    private func lineEditor(_ text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text).font(.body).scrollContentBackground(.hidden).padding(Metrics.label)
            .frame(height: height).background(.background, in: RoundedRectangle(cornerRadius: Metrics.control))
    }

    /// Moving the start past the end pushes the end an hour after it, so work hours never come out empty.
    private var startBinding: Binding<Int> {
        Binding(get: { draft.workStart }, set: { draft.workStart = $0; draft.workEnd = max(draft.workEnd, $0 + 60) })
    }

    private func hour(_ h: Int) -> String { String(format: "%02d:00", h) }

    private func save() {
        (draft.domains, draft.apps) = (lines(domains), lines(apps))
        (draft.iPhone, draft.iPhoneName) = (model.settings.iPhone, model.settings.iPhoneName)   // may have been found since the window opened
        model.settings = draft
        model.saveSettings()
    }

    private func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { String($0).trimmed }.filter { !$0.isEmpty }
    }
}
