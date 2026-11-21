import SwiftUI

struct RunsRailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.geomagTheme) private var theme
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(
                    title: "运行记录",
                    trailing: headerCount
                )
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        model.toggleComparisonSelectionMode()
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(
                            systemName: model.comparisonSelecting
                                ? "square.on.square.fill"
                                : "square.on.square"
                        )
                        .font(.system(size: 9, weight: .medium))
                        Text("对比")
                            .font(ThemeFont.caption(9))
                    }
                    .foregroundStyle(
                        model.comparisonSelecting ? theme.signal : theme.muted
                    )
                }
                .buttonStyle(.plain)
                .help(
                    model.comparisonActive
                        ? "退出多运行对比"
                        : model.comparisonSelecting
                            ? "结束对比选择"
                            : "选择 2–4 条运行进行对比"
                )

                Button {
                    model.refreshRunHistory()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(theme.muted)
                }
                .buttonStyle(.plain)
                .help("刷新历史结果")

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        model.runsRailVisible = false
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.muted)
                }
                .buttonStyle(.plain)
                .help("收起运行记录")
            }
            .padding(.horizontal, 12)
            .padding(.top, 14)

            Text(
                model.comparisonSelecting
                    ? "勾选 2–4 条运行做对比；点击行即可增减，实时更新。"
                    : "点击打开历史结果，只读显示，不改动当前管线。"
            )
            .font(ThemeFont.caption(9))
            .foregroundStyle(theme.faint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)

            if let notice = model.comparisonNotice {
                Text(notice)
                    .font(ThemeFont.caption(9))
                    .foregroundStyle(theme.warn)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
            }

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(theme.muted)
                TextField("搜索运行…", text: $query)
                    .textFieldStyle(.plain)
                    .font(ThemeFont.caption(9.5))
                    .foregroundStyle(theme.ink)
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: ThemeMetrics.badgeRadius)
                    .fill(theme.surfaceSecondary)
            )
            .padding(.horizontal, 12)

            ScrollView {
                LazyVStack(spacing: 3) {
                    if filteredRuns.isEmpty {
                        Text(
                            query.isEmpty
                                ? "还没有历史结果。运行一次定位后会出现在这里。"
                                : "没有匹配的运行记录。"
                        )
                        .font(ThemeFont.caption(9.5))
                        .foregroundStyle(theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                    } else {
                        ForEach(sections) { section in
                            Text(section.title.uppercased())
                                .font(ThemeFont.micro(8, weight: .bold))
                                .tracking(1.2)
                                .foregroundStyle(theme.faint)
                                .padding(.horizontal, 4)
                                .padding(.top, 5)
                                .padding(.bottom, 2)
                            ForEach(section.runs) { run in
                                runRow(run)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }

            Hairline()
            footer
                .padding(10)
        }
        .background(theme.surface)
    }

    @ViewBuilder
    private var footer: some View {
        if model.comparisonSelecting {
            VStack(spacing: 7) {
                HStack(spacing: 6) {
                    Text("已选 \(model.comparisonSelection.count)/\(RunComparison.maximumRunCount)")
                        .font(ThemeFont.mono(8.5))
                        .foregroundStyle(theme.muted)
                    if !model.comparisonSelection.isEmpty {
                        Text("· 基准 \(model.comparisonBaselineLetter)")
                            .font(ThemeFont.mono(8.5))
                            .foregroundStyle(theme.signal)
                    }
                    Spacer()
                    ForEach(model.comparisonSelection) { run in
                        if let index = model.comparisonColorIndex(for: run) {
                            Circle()
                                .fill(theme.comparisonColor(index))
                                .frame(width: 6, height: 6)
                        }
                    }
                }

                if model.comparisonActive {
                    PlateButton(
                        title: "退出对比",
                        systemImage: "xmark",
                        kind: .secondary
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            model.endComparison()
                        }
                    }
                    Text("继续勾选会实时更新对比结果。")
                        .font(ThemeFont.caption(8.5))
                        .foregroundStyle(theme.faint)
                } else {
                    PlateButton(
                        title: "对比 \(model.comparisonSelection.count) 项",
                        systemImage: "square.on.square",
                        kind: .primary,
                        isEnabled: model.canStartComparison
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            model.startComparison()
                        }
                    }
                    HStack(spacing: 6) {
                        PlateButton(
                            title: "清空",
                            kind: .ghost,
                            isEnabled: !model.comparisonSelection.isEmpty
                        ) {
                            model.clearComparisonSelection()
                        }
                        PlateButton(title: "退出选择", kind: .ghost) {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                model.toggleComparisonSelectionMode()
                            }
                        }
                    }
                }
            }
        } else {
            VStack(spacing: 6) {
                PlateButton(
                    title: "打开结果 JSON…",
                    systemImage: "folder",
                    kind: .secondary
                ) {
                    model.openResultFile()
                }
                PlateButton(
                    title: "打开结果目录",
                    systemImage: "folder",
                    kind: .ghost
                ) {
                    model.openRunsDirectory()
                }
            }
        }
    }

    private func runRow(_ run: RunRecord) -> some View {
        let active = model.loadedFileName == run.jsonURL.lastPathComponent
        let summary = model.runSummaries[run.jsonURL.path]
        let selecting = model.comparisonSelecting
        let selected = model.isComparisonSelected(run)
        let colorIndex = model.comparisonColorIndex(for: run)
        let baseline = model.comparisonSelecting && model.comparisonBaselineID == run.id
        let accent = colorIndex.map(theme.comparisonColor) ?? theme.signal

        return Button {
            if selecting {
                withAnimation(.easeInOut(duration: 0.15)) {
                    model.toggleComparisonSelection(run)
                }
            } else {
                model.loadRun(run)
            }
        } label: {
            HStack(alignment: .top, spacing: 7) {
                if selecting {
                    comparisonBox(selected: selected, colorIndex: colorIndex)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text(run.displayName)
                            .font(ThemeFont.title(11, weight: .semibold))
                            .foregroundStyle(theme.ink)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if baseline {
                            Text("基准")
                                .font(ThemeFont.micro(7.5))
                                .foregroundStyle(theme.signal)
                        } else if active {
                            Text("当前")
                                .font(ThemeFont.micro(7.5))
                                .foregroundStyle(theme.signal)
                        } else if selecting, selected, let colorIndex {
                            Text(RunComparison.letter(for: colorIndex))
                                .font(ThemeFont.mono(8, weight: .bold))
                                .foregroundStyle(theme.comparisonColor(colorIndex))
                        }
                    }
                    HStack(spacing: 4) {
                        Text(Self.timeFormatter.string(from: run.modifiedAt))
                            .font(ThemeFont.mono(8.5))
                            .foregroundStyle(theme.faint)
                        if let steps = summary?.stepsDetected {
                            Text("· \(steps) 步")
                                .font(ThemeFont.mono(8.5))
                                .foregroundStyle(theme.faint)
                        }
                        Spacer(minLength: 4)
                        if let final = summary?.pfFinalError {
                            Text(String(format: "PF %.2f m", final))
                                .font(ThemeFont.mono(8.5))
                                .foregroundStyle(theme.trace)
                        }
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: ThemeMetrics.controlRadius)
                    .fill(
                        selected
                            ? theme.signalSoft.opacity(0.55)
                            : active ? theme.surfaceSecondary : .clear
                    )
            )
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(accent)
                        .frame(width: 2)
                        .padding(.vertical, 7)
                } else if active {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(theme.signal)
                        .frame(width: 2)
                        .padding(.vertical, 7)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(
            selecting
                ? (selected ? "从对比中移除 \(run.displayName)" : "将 \(run.displayName) 加入对比")
                : run.jsonURL.path
        )
        .accessibilityValue(
            selecting
                ? (selected ? "已加入对比" : "未加入对比")
                : (active ? "当前结果" : "")
        )
    }

    private func comparisonBox(selected: Bool, colorIndex: Int?) -> some View {
        let color = colorIndex.map(theme.comparisonColor) ?? theme.signal
        return ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(selected ? color : Color.clear)
            RoundedRectangle(cornerRadius: 3)
                .stroke(selected ? color : theme.hairline, lineWidth: 1)
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(theme.plotBackground)
            }
        }
        .frame(width: 14, height: 14)
        .padding(.top, 2)
    }

    private var filteredRuns: [RunRecord] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return model.recentRuns }
        return model.recentRuns.filter {
            $0.displayName.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var headerCount: String {
        let total = model.recentRuns.count
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "\(total)"
        }
        return "\(filteredRuns.count)/\(total)"
    }

    private var sections: [RunDaySection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: filteredRuns) {
            calendar.startOfDay(for: $0.modifiedAt)
        }
        return grouped.keys.sorted(by: >).map { day in
            RunDaySection(
                day: day,
                title: dayTitle(day),
                runs: (grouped[day] ?? []).sorted {
                    $0.modifiedAt > $1.modifiedAt
                }
            )
        }
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "今天" }
        if calendar.isDateInYesterday(day) { return "昨天" }
        return Self.dayFormatter.string(from: day)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

private struct RunDaySection: Identifiable {
    let day: Date
    let title: String
    let runs: [RunRecord]

    var id: Date { day }
}
