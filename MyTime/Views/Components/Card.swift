import SwiftUI

/// Rounded, softly filled container shared by the popover and main window.
struct CardModifier: ViewModifier {
    var padding: CGFloat = 16
    var cornerRadius: CGFloat = 14
    var tint: Color? = nil
    var highlighted = false

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(tint.map { AnyShapeStyle($0.opacity(0.12)) } ?? AnyShapeStyle(.quaternary.opacity(0.55)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(highlighted ? AnyShapeStyle((tint ?? .accentColor).opacity(0.7)) : AnyShapeStyle(.separator.opacity(0.6)),
                                  lineWidth: highlighted ? 1.5 : 1)
            }
    }
}

extension View {
    func card(padding: CGFloat = 16, cornerRadius: CGFloat = 14, tint: Color? = nil, highlighted: Bool = false) -> some View {
        modifier(CardModifier(padding: padding, cornerRadius: cornerRadius, tint: tint, highlighted: highlighted))
    }
}

/// Small rounded label, e.g. "Fixed fee" or "Non-billable".
struct Tag: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: .capsule)
    }
}

/// Client logo in a circle, or initials on a colour that's stable per name.
struct Avatar: View {
    let name: String
    var size: CGFloat = 32
    var imageData: Data? = nil

    private static let palette: [Color] = [.teal, .blue, .indigo, .purple, .pink, .orange, .green, .cyan]

    private var initials: String {
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true }
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }

    private var color: Color {
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return Self.palette[hash % Self.palette.count]
    }

    var body: some View {
        if let imageData, let image = NSImage(data: imageData) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .padding(size * 0.14)
                .frame(width: size, height: size)
                .background(.white, in: .circle)
                .overlay(Circle().strokeBorder(.separator.opacity(0.6), lineWidth: 1))
        } else {
            Text(initials.isEmpty ? "?" : initials)
                .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(color.gradient, in: .circle)
        }
    }
}

/// Section title with an optional trailing control, used above cards.
struct SectionTitle<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            Spacer()
            trailing
        }
        .padding(.horizontal, 4)
    }
}

extension SectionTitle where Trailing == EmptyView {
    init(_ title: String) {
        self.title = title
        self.trailing = EmptyView()
    }
}

/// A small headline number with a caption, for summary cards.
struct StatCard: View {
    let title: String
    let value: String
    var systemImage: String
    var tint: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(tint ?? .secondary)
            Text(value)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .card(padding: 12, cornerRadius: 12, tint: tint)
    }
}

/// Label + field row for detail cards.
struct DetailField<Field: View>: View {
    let label: String
    @ViewBuilder var field: Field

    var body: some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            field
                .textFieldStyle(.roundedBorder)
        }
    }
}
