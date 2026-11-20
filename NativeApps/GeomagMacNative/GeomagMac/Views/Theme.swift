import SwiftUI

struct Theme {
    let canvas: Color
    let surface: Color
    let surfaceSecondary: Color
    let raised: Color
    let hairline: Color
    let hairlineSoft: Color
    let grid: Color
    let ink: Color
    let muted: Color
    let faint: Color
    let signal: Color
    let signalOn: Color
    let signalSoft: Color
    let trace: Color
    let traceSoft: Color
    let warn: Color
    let danger: Color

    let plotBackground: Color
    let plotGrid: Color
    let plotGridMajor: Color
    let plotInk: Color
    let plotMuted: Color
    let plotBoundary: Color
    let trueRoute: Color
    let pdr: Color
    let pf: Color
    let confidenceHigh: Color
    let confidenceMedium: Color
    let confidenceLow: Color

    static let light = Theme(
        canvas: Color(red: 0.9608, green: 0.9529, blue: 0.9333),
        surface: .white,
        surfaceSecondary: Color(red: 0.9255, green: 0.9176, blue: 0.8902),
        raised: .white,
        hairline: Color(red: 0.8471, green: 0.8314, blue: 0.7882),
        hairlineSoft: Color(red: 0.9020, green: 0.8863, blue: 0.8431),
        grid: Color(red: 0.8902, green: 0.8784, blue: 0.8431),
        ink: Color(red: 0.0784, green: 0.0941, blue: 0.1137),
        muted: Color(red: 0.3529, green: 0.3843, blue: 0.4392),
        faint: Color(red: 0.4784, green: 0.5098, blue: 0.5647),
        signal: Color(red: 0.0392, green: 0.3490, blue: 0.9686),
        signalOn: .white,
        signalSoft: Color(red: 0.9098, green: 0.9373, blue: 0.9961),
        trace: Color(red: 0.0392, green: 0.4510, blue: 0.3333),
        traceSoft: Color(red: 0.8941, green: 0.9529, blue: 0.9333),
        warn: Color(red: 0.7059, green: 0.3255, blue: 0.0353),
        danger: Color(red: 0.7608, green: 0.2549, blue: 0.0471),
        plotBackground: Color(red: 0.0549, green: 0.0706, blue: 0.0941),
        plotGrid: Color.white.opacity(0.055),
        plotGridMajor: Color.white.opacity(0.12),
        plotInk: Color(red: 0.9098, green: 0.9255, blue: 0.9490),
        plotMuted: Color(red: 0.5451, green: 0.5843, blue: 0.6431),
        plotBoundary: Color.white.opacity(0.24),
        trueRoute: Color(red: 0.9490, green: 0.9412, blue: 0.9098),
        pdr: Color(red: 0.3020, green: 0.6078, blue: 1.0),
        pf: Color(red: 0.3608, green: 0.9490, blue: 0.7804),
        confidenceHigh: Color(red: 0.3608, green: 0.9490, blue: 0.7804),
        confidenceMedium: Color(red: 1.0, green: 0.7059, blue: 0.3294),
        confidenceLow: Color(red: 1.0, green: 0.4196, blue: 0.3412)
    )

    static let dark = Theme(
        canvas: Color(red: 0.0431, green: 0.0549, blue: 0.0745),
        surface: Color(red: 0.0706, green: 0.0863, blue: 0.1137),
        surfaceSecondary: Color(red: 0.1020, green: 0.1255, blue: 0.1608),
        raised: Color(red: 0.1490, green: 0.1882, blue: 0.2549),
        hairline: Color(red: 0.1647, green: 0.1961, blue: 0.2431),
        hairlineSoft: Color(red: 0.1333, green: 0.1647, blue: 0.2078),
        grid: Color(red: 0.1216, green: 0.1529, blue: 0.2000),
        ink: Color(red: 0.9098, green: 0.9255, blue: 0.9490),
        muted: Color(red: 0.6039, green: 0.6471, blue: 0.7059),
        faint: Color(red: 0.4196, green: 0.4627, blue: 0.5255),
        signal: Color(red: 0.3020, green: 0.6078, blue: 1.0),
        signalOn: Color(red: 0.0235, green: 0.0627, blue: 0.1216),
        signalSoft: Color(red: 0.0863, green: 0.1490, blue: 0.2392),
        trace: Color(red: 0.3608, green: 0.9490, blue: 0.7804),
        traceSoft: Color(red: 0.0627, green: 0.1647, blue: 0.1451),
        warn: Color(red: 1.0, green: 0.7059, blue: 0.3294),
        danger: Color(red: 1.0, green: 0.4196, blue: 0.3412),
        plotBackground: Color(red: 0.0275, green: 0.0392, blue: 0.0588),
        plotGrid: Color.white.opacity(0.06),
        plotGridMajor: Color.white.opacity(0.13),
        plotInk: Color(red: 0.9098, green: 0.9255, blue: 0.9490),
        plotMuted: Color(red: 0.4863, green: 0.5294, blue: 0.5961),
        plotBoundary: Color.white.opacity(0.24),
        trueRoute: Color(red: 0.6824, green: 0.7216, blue: 0.7765),
        pdr: Color(red: 0.3020, green: 0.6078, blue: 1.0),
        pf: Color(red: 0.3608, green: 0.9490, blue: 0.7804),
        confidenceHigh: Color(red: 0.3608, green: 0.9490, blue: 0.7804),
        confidenceMedium: Color(red: 1.0, green: 0.7059, blue: 0.3294),
        confidenceLow: Color(red: 1.0, green: 0.4196, blue: 0.3412)
    )

    static func resolve(_ scheme: ColorScheme) -> Theme {
        scheme == .dark ? .dark : .light
    }
}

enum ThemeFont {
    static func display(_ size: CGFloat = 20) -> Font {
        .system(size: size, weight: .semibold)
    }

    static func title(_ size: CGFloat = 13, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight)
    }

    static func label(_ size: CGFloat = 11, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight)
    }

    static func caption(_ size: CGFloat = 10, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func micro(_ size: CGFloat = 9, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat = 11, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

enum ThemeMetrics {
    static let pagePadding: CGFloat = 20
    static let sectionGap: CGFloat = 16
    static let panelRadius: CGFloat = 12
    static let cardRadius: CGFloat = 10
    static let controlRadius: CGFloat = 8
    static let badgeRadius: CGFloat = 6
    static let hairline: CGFloat = 1
    static let controlHeight: CGFloat = 32
    static let primaryHeight: CGFloat = 34
    static let fieldHeight: CGFloat = 44
    static let railWidth: CGFloat = 236
    static let inspectorWidth: CGFloat = 300
    static let statusHeight: CGFloat = 26
    static let topBarHeight: CGFloat = 92
}

private struct ThemeEnvironmentKey: EnvironmentKey {
    static let defaultValue = Theme.light
}

extension EnvironmentValues {
    var geomagTheme: Theme {
        get { self[ThemeEnvironmentKey.self] }
        set { self[ThemeEnvironmentKey.self] = newValue }
    }
}

extension View {
    func geomagTheme(_ theme: Theme) -> some View {
        environment(\.geomagTheme, theme)
    }
}
