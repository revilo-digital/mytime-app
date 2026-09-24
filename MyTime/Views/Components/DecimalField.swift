import SwiftUI

/// Text field for an optional Decimal (e.g. a rate override). Empty text means nil.
struct OptionalDecimalField: View {
    let title: String
    @Binding var value: Decimal?
    var prompt: String = ""

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text, prompt: Text(prompt))
            .focused($focused)
            .onAppear { text = Self.string(value) }
            .onChange(of: value) { if !focused { text = Self.string(value) } }
            .onChange(of: text) { value = Self.parse(text) }
            .onChange(of: focused) { if !focused { text = Self.string(value) } }
    }

    static func string(_ value: Decimal?) -> String {
        value.map { "\($0)" } ?? ""
    }

    static func parse(_ text: String) -> Decimal? {
        let cleaned = text.replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : Decimal(string: cleaned)
    }
}

/// Non-optional variant; empty text means zero.
struct DecimalField: View {
    let title: String
    @Binding var value: Decimal

    var body: some View {
        OptionalDecimalField(
            title: title,
            value: Binding(get: { value }, set: { value = $0 ?? 0 }),
            prompt: "0"
        )
    }
}

/// Edits a decimal-hours quantity as real time ("1:30"). Also accepts "1.5", "90m", "1h 30m".
struct HoursField: View {
    @Binding var hours: Decimal?

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Time", text: $text, prompt: Text("0:00"))
            .focused($focused)
            .help("Hours and minutes, e.g. 1:30")
            .onAppear { text = Self.string(hours) }
            .onChange(of: hours) { if !focused { text = Self.string(hours) } }
            .onSubmit(commit)
            .onChange(of: focused) { if !focused { commit() } }
    }

    private func commit() {
        if let seconds = DurationFormat.parse(text) {
            hours = Decimal(Int(seconds.rounded()) / 60) / 60
        }
        text = Self.string(hours)
    }

    static func string(_ hours: Decimal?) -> String {
        hours.map(HoursFormat.clock) ?? ""
    }
}
