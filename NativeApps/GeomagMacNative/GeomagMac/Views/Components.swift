import SwiftUI

enum PlateButtonKind {
    case primary
    case secondary
    case ghost
    case danger
}

struct PlateButton: View {
    let title: String
    var systemImage: String?
    var kind: PlateButtonKind = .secondary
    var isEnabled: Bool = true
    var action: () -> Void

    @Environment(\.geomagTheme) private var theme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .medium))
                }
                Text(title)
                    .font(ThemeFont.label(11, weight: kind == .primary ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .frame(height: kind == .primary ? ThemeMetrics.primaryHeight : ThemeMetrics.controlHeight)
            .background(background, in: RoundedRectangle(cornerRadius: ThemeMetrics.controlRadius))
            .overlay {
                RoundedRectangle(cornerRadius: ThemeMetrics.controlRadius)
                    .stroke(borderColor, lineWidth: ThemeMetrics.hairline)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.42)
        .onHover { isHovered = $0 }
    }

    private var foreground: Color {
        switch kind {
        case .primary: theme.signalOn
        case .secondary: theme.ink
        case .ghost: theme.muted
        case .danger: theme.danger
        }
    }

    private var background: Color {
        switch kind {
        case .primary:
            theme.signal
        case .secondary:
            isHovered ? theme.surfaceSecondary : theme.surface
        case .ghost:
            isHovered ? theme.surfaceSecondary : .clear
        case .danger:
            isHovered ? theme.danger.opacity(0.08) : .clear
        }
    }

    private var borderColor: Color {
        switch kind {
        case .primary: .clear
        case .secondary: theme.hairline
        case .ghost: .clear
        case .danger: theme.hairline
        }
    }
}

struct SegmentedRail<Item: Hashable>: View {
    let items: [Item]
    let title: (Item) -> String
    @Binding var selection: Item

    @Environment(\.geomagTheme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                Button {
                    selection = item
                } label: {
                    Text(title(item))
                        .font(ThemeFont.label(11, weight: selection == item ? .semibold : .regular))
                        .foregroundStyle(selection == item ? theme.ink : theme.muted)
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .background {
                            if selection == item {
                                RoundedRectangle(cornerRadius: ThemeMetrics.badgeRadius)
                                    .fill(theme.raised)
                                    .overlay(alignment: .bottom) {
                                        Rectangle()
                                            .fill(theme.signal)
                                            .frame(height: 2)
                                            .clipShape(
                                                UnevenRoundedRectangle(
                                                    bottomLeadingRadius: 1,
                                                    bottomTrailingRadius: 1
                                                )
                                            )
                                    }
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: ThemeMetrics.controlRadius)
                .fill(theme.surfaceSecondary)
        )
    }
}

struct Panel<Content: View>: View {
    var padding: CGFloat
    let content: Content

    @Environment(\.geomagTheme) private var theme

    init(padding: CGFloat = 14, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: ThemeMetrics.cardRadius)
                    .fill(theme.surface)
            )
            .overlay {
                RoundedRectangle(cornerRadius: ThemeMetrics.cardRadius)
                    .stroke(theme.hairlineSoft, lineWidth: ThemeMetrics.hairline)
            }
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: String?

    @Environment(\.geomagTheme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(ThemeFont.micro(9, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(theme.muted)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(ThemeFont.mono(9))
                    .foregroundStyle(theme.faint)
            }
        }
    }
}

struct Hairline: View {
    @Environment(\.geomagTheme) private var theme

    var body: some View {
        Rectangle()
            .fill(theme.hairlineSoft)
            .frame(height: ThemeMetrics.hairline)
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    var unit: String?
    var compare: String?
    var delta: String?
    var tint: Color?

    @Environment(\.geomagTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(title)
                    .font(ThemeFont.caption(9))
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
                Spacer(minLength: 2)
                if let delta {
                    Text(delta)
                        .font(ThemeFont.mono(8))
                        .foregroundStyle(tint ?? theme.trace)
                        .lineLimit(1)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(ThemeFont.mono(19, weight: .semibold))
                    .foregroundStyle(theme.ink)
                    .monospacedDigit()
                    .lineLimit(1)
                if let unit {
                    Text(unit)
                        .font(ThemeFont.mono(9))
                        .foregroundStyle(theme.muted)
                }
            }
            if let compare {
                Text(compare)
                    .font(ThemeFont.mono(8.5))
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ThemeMetrics.cardRadius)
                .fill(theme.surface)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(tint ?? theme.trace)
                .frame(width: 2)
                .padding(.vertical, 9)
        }
        .overlay {
            RoundedRectangle(cornerRadius: ThemeMetrics.cardRadius)
                .stroke(theme.hairlineSoft, lineWidth: ThemeMetrics.hairline)
        }
    }
}

struct StatusPill: View {
    let text: String
    var tint: Color?

    @Environment(\.geomagTheme) private var theme

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint ?? theme.trace)
                .frame(width: 6, height: 6)
            Text(text)
                .font(ThemeFont.label(10))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Capsule().fill(theme.surface))
        .overlay(Capsule().stroke(theme.hairline, lineWidth: ThemeMetrics.hairline))
    }
}

enum LineSwatchStyle {
    case solid
    case dashed
    case confidence
}

struct LineSwatch: View {
    let style: LineSwatchStyle
    let color: Color
    var width: CGFloat = 22

    var body: some View {
        Canvas { context, size in
            let y = size.height / 2
            var path = Path()
            switch style {
            case .solid:
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(color), lineWidth: 2)
            case .dashed:
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(
                    path,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])
                )
            case .confidence:
                let rect = CGRect(
                    x: 2,
                    y: max((size.height - 7) / 2, 0),
                    width: max(size.width - 4, 1),
                    height: 7
                )
                context.stroke(
                    Path(ellipseIn: rect),
                    with: .color(color.opacity(0.8)),
                    lineWidth: 1
                )
            }
        }
        .frame(width: width, height: 8)
    }
}

struct PlateToggleStyle: ToggleStyle {
    let theme: Theme

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? theme.signalSoft : theme.surfaceSecondary)
                    .overlay(
                        Capsule().stroke(
                            configuration.isOn ? theme.signal : theme.hairline,
                            lineWidth: ThemeMetrics.hairline
                        )
                    )
                Circle()
                    .fill(configuration.isOn ? theme.signal : theme.faint)
                    .frame(width: 9, height: 9)
                    .padding(.horizontal, 2)
            }
            .frame(width: 26, height: 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "开" : "关")
    }
}

struct ToggleRow: View {
    let title: String
    let swatchStyle: LineSwatchStyle
    let swatchColor: Color
    @Binding var isOn: Bool

    @Environment(\.geomagTheme) private var theme

    var body: some View {
        HStack(spacing: 9) {
            LineSwatch(style: swatchStyle, color: swatchColor)
            Text(title)
                .font(ThemeFont.caption(10.5))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
            Spacer(minLength: 4)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(PlateToggleStyle(theme: theme))
                .accessibilityLabel(title)
        }
        .frame(minHeight: 22)
    }
}

enum StageBadgeState {
    case done
    case active
    case ready
    case blocked
    case attention
    case running
}

struct StageBadge: View {
    let stage: Stage
    let state: StageBadgeState
    var subtitle: String?

    @Environment(\.geomagTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(String(format: "%02d", stage.rawValue + 1))
                    .font(ThemeFont.mono(9))
                    .foregroundStyle(numberColor)
                Text(stage.title)
                    .font(ThemeFont.title(12, weight: state == .active ? .bold : .semibold))
                    .foregroundStyle(nameColor)
                if state == .done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(theme.trace)
                }
            }
            if let subtitle {
                Text(subtitle)
                    .font(ThemeFont.mono(9))
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var numberColor: Color {
        switch state {
        case .active: theme.signal
        case .done: theme.trace
        case .blocked: theme.danger
        case .attention: theme.warn
        case .ready, .running: theme.faint
        }
    }

    private var nameColor: Color {
        switch state {
        case .active, .done: theme.ink
        case .blocked: theme.danger
        case .ready, .attention, .running: theme.muted
        }
    }

    private var subtitleColor: Color {
        switch state {
        case .active: theme.signal
        case .blocked: theme.danger
        case .attention: theme.warn
        case .done: theme.muted
        case .ready, .running: theme.faint
        }
    }
}

enum NoticeSeverity {
    case info
    case warn
    case error
}

struct NoticeBanner: View {
    let severity: NoticeSeverity
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    @Environment(\.geomagTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(tint)
                .frame(width: 2)
                .clipShape(Capsule())
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 1)
            Text(message)
                .font(ThemeFont.caption(10.5))
                .foregroundStyle(theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 6)
            if let actionTitle, let action {
                PlateButton(title: actionTitle, kind: .ghost, action: action)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: ThemeMetrics.cardRadius)
                .fill(theme.surface)
        )
        .overlay {
            RoundedRectangle(cornerRadius: ThemeMetrics.cardRadius)
                .stroke(theme.hairlineSoft, lineWidth: ThemeMetrics.hairline)
        }
    }

    private var tint: Color {
        switch severity {
        case .info: theme.signal
        case .warn: theme.warn
        case .error: theme.danger
        }
    }

    private var icon: String {
        switch severity {
        case .info: "info.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }
}

struct FieldSlot<Content: View>: View {
    let content: Content

    @Environment(\.geomagTheme) private var theme

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 12)
            .frame(minHeight: ThemeMetrics.fieldHeight)
            .background(
                RoundedRectangle(cornerRadius: ThemeMetrics.controlRadius)
                    .fill(theme.surfaceSecondary)
            )
            .overlay {
                RoundedRectangle(cornerRadius: ThemeMetrics.controlRadius)
                    .stroke(theme.hairlineSoft, lineWidth: ThemeMetrics.hairline)
            }
    }
}

struct BrandMark: View {
    var size: CGFloat = 28

    @Environment(\.geomagTheme) private var theme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.surface)
            RoundedRectangle(cornerRadius: 6)
                .stroke(theme.ink, lineWidth: 1)
            Path { path in
                path.move(to: CGPoint(x: size * 0.25, y: size * 0.75))
                path.addLine(to: CGPoint(x: size * 0.25, y: size * 0.3))
                path.addLine(to: CGPoint(x: size * 0.75, y: size * 0.3))
                path.addLine(to: CGPoint(x: size * 0.75, y: size * 0.7))
            }
            .stroke(theme.signal, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            Circle()
                .fill(theme.trace)
                .frame(width: 3, height: 3)
                .position(x: size * 0.25, y: size * 0.75)
        }
        .frame(width: size, height: size)
    }
}

struct KeyCap: View {
    let text: String

    @Environment(\.geomagTheme) private var theme

    var body: some View {
        Text(text)
            .font(ThemeFont.mono(8))
            .foregroundStyle(theme.muted)
            .padding(.horizontal, 4)
            .frame(height: 16)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(theme.surfaceSecondary)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 3)
                    .stroke(theme.hairlineSoft, lineWidth: ThemeMetrics.hairline)
            }
    }
}
