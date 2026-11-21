import SwiftUI

struct InspectorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.geomagTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "图层")
                .id("layers")
            ToggleRow(
                title: "真实路线",
                swatchStyle: .dashed,
                swatchColor: theme.trueRoute.opacity(0.75),
                isOn: $model.showTrueRoute
            )
            ToggleRow(
                title: "PDR 路线",
                swatchStyle: .solid,
                swatchColor: theme.pdr,
                isOn: $model.showPDR
            )
            ToggleRow(
                title: "PF 地磁匹配",
                swatchStyle: .solid,
                swatchColor: theme.pf,
                isOn: $model.showPF
            )
            ToggleRow(
                title: "置信范围",
                swatchStyle: .confidence,
                swatchColor: theme.confidenceHigh,
                isOn: $model.showPFConfidence
            )
            .disabled(model.result?.pfConfidenceHistory?.isEmpty != false)

            Hairline()
            SectionHeader(title: "选中步")
                .id("selectedStep")
            selectedStepCard

            Hairline()
            SectionHeader(title: "诊断")
                .id("diagnostics")
            if let result = model.result {
                VStack(spacing: 5) {
                    if let heading = result.headingDiagnostics {
                        infoRow("航向来源", heading.localizedMethod)
                        if let ratio = heading.calibratedRatio {
                            infoRow(
                                "姿态磁校准",
                                "\(Int((ratio * 100).rounded()))%"
                            )
                        }
                        if let reason = heading.localizedRejectionReason {
                            infoRow("姿态回退", reason)
                        }
                    }
                    if let score = result.overallPFConfidenceScore {
                        infoRow(
                            "平均可靠度",
                            "\(Int((score * 100).rounded()))% · "
                                + (result.overallPFConfidenceLevel ?? "—")
                        )
                    }
                    if let final = result.finalPFConfidence {
                        infoRow(
                            "末端可靠度",
                            "\(final.localizedLevel) · \(Int((final.score * 100).rounded()))%"
                        )
                        if let radius = final.coreRadius80M {
                            infoRow("核心半径 r80", meters(radius))
                        }
                    }
                    if let mean = result.meanPFGlobalAmbiguity,
                       let maximum = result.maximumPFGlobalAmbiguity {
                        infoRow(
                            "位置歧义",
                            "平均 \(Int((mean * 100).rounded()))% · 峰值 \(Int((maximum * 100).rounded()))%"
                        )
                    }
                    if let interval = result.activeWalkInterval {
                        infoRow("有效行走", String(format: "%.1f s", interval.duration))
                    }
                    if let steps = result.stepsDetected {
                        infoRow("检测步数", "\(steps)")
                    }
                }
            } else {
                Text("尚未加载结果。")
                    .font(ThemeFont.caption(10))
                    .foregroundStyle(theme.muted)
            }

            Hairline()
            SectionHeader(title: "当前磁图")
            mapCard


        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selectedStepCard: some View {
        Group {
            if let result = model.result,
               let selected = model.selectedStepIndex,
               let sample = TrajectoryAnalysis.stepSamples(for: result)
                .first(where: { $0.id == selected }) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("PF 第 \(sample.id) 步")
                            .font(ThemeFont.title(12, weight: .semibold))
                            .foregroundStyle(theme.ink)
                        Spacer()
                        Text(sample.confidence?.localizedLevel ?? "—")
                            .font(ThemeFont.mono(9))
                            .foregroundStyle(theme.muted)
                    }
                    infoRow("PF 横向偏差", meters(sample.pfLateralError))
                    infoRow("PDR 横向偏差", meters(sample.pdrLateralError))
                    if let confidence = sample.confidence {
                        infoRow(
                            "可靠度",
                            "\(Int((confidence.score * 100).rounded()))%"
                        )
                    }
                    if let health = sample.health {
                        infoRow("定位状态", health.localizedStatus)
                    }
                    Text("点击画布或按 ←/→ 切换；Esc 取消固定。")
                        .font(ThemeFont.caption(9))
                        .foregroundStyle(theme.faint)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: ThemeMetrics.cardRadius)
                        .fill(theme.surface)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: ThemeMetrics.cardRadius)
                        .stroke(theme.hairlineSoft, lineWidth: 1)
                }
            } else {
                Text("点击轨迹或按 ←/→ 选择一步；选中后这里显示该步的 PF/PDR 横向偏差。")
                    .font(ThemeFont.caption(9.5))
                    .foregroundStyle(theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var mapCard: some View {
        Group {
            if let map = model.mapForCurrentSelection {
                let document = map.document
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(document.name)
                            .font(ThemeFont.title(11.5, weight: .semibold))
                            .foregroundStyle(theme.ink)
                            .lineLimit(1)
                        Spacer()
                        Text(map.isBuiltIn ? "内置" : "用户")
                            .font(ThemeFont.micro(8))
                            .foregroundStyle(theme.faint)
                    }
                    Text(
                        (document.localizationMode == .routeCorridorValidation ? "路线磁图" : "网格磁图")
                            + " · \(document.samples.count) 采样"
                            + (document.gridCellSizeM.map {
                                String(format: " · %.2f m", $0)
                            } ?? "")
                    )
                    .font(ThemeFont.mono(8.5))
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
                    Text("参考 \(document.sourceLabel)")
                        .font(ThemeFont.mono(8.5))
                        .foregroundStyle(theme.faint)
                        .lineLimit(1)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: ThemeMetrics.cardRadius)
                        .fill(theme.surface)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: ThemeMetrics.cardRadius)
                        .stroke(theme.hairlineSoft, lineWidth: 1)
                }
            } else {
                Text("当前没有选中的磁图。")
                    .font(ThemeFont.caption(9.5))
                    .foregroundStyle(theme.muted)
            }
        }
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(ThemeFont.caption(9))
                .foregroundStyle(theme.muted)
            Spacer(minLength: 4)
            Text(value)
                .font(ThemeFont.mono(9))
                .foregroundStyle(theme.ink)
                .lineLimit(1)
        }
    }

    private func meters(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.2f m", value)
    }

}
