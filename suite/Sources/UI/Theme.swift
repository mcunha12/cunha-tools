import AppKit
import SwiftUI

enum Palette {
    static let accent = Color(hex: 0x3A9C94)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let closed = Color(hex: 0x5BA8C9)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    // Accepts "#RRGGBB" or "RRGGBB", as written in CunhaToolTint.
    init?(hexString: String) {
        let digits = hexString.hasPrefix("#") ? String(hexString.dropFirst()) : hexString
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(hex: value)
    }
}

extension ToolBundle {
    var tintColor: Color { tint.flatMap(Color.init(hexString:)) ?? Palette.accent }
}

// SF Symbol on a rounded square: tinted glass by default, solid gradient when filled.
struct IconTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 44
    var filled = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(filled ? Color.white : tint)
            .frame(width: size, height: size)
            .background(shape.fill(filled ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(tint.opacity(0.16))))
            .overlay(shape.strokeBorder(tint.opacity(filled ? 0 : 0.22), lineWidth: 1))
    }
}

struct PageHeader<Trailing: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 34, weight: .bold))
                Text(subtitle).font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            trailing
        }
    }
}

struct StatusPill: View {
    let text: String
    let symbol: String
    let color: Color
    var caption: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            Label(text, systemImage: symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(color.opacity(0.14)))
            if let caption { Text(caption).font(.callout).foregroundStyle(.secondary) }
        }
    }
}

struct SectionHeader: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title2.weight(.semibold))
            Spacer(minLength: 12)
            if let detail { Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
        }
        .padding(.top, 8)
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

extension View {
    func card(padding: CGFloat = 22) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.card))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.05)))
    }
}

func counted(_ count: Int, _ singular: String, _ plural: String) -> String {
    "\(count) \(count == 1 ? singular : plural)"
}
