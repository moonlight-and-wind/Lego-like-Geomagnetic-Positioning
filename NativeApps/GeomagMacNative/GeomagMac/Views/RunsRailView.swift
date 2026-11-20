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

            Text("点击打开历史结果，只读显示，不改动当前管线。")
                .font(ThemeFont.caption(9))
                .foregroundStyle(theme.faint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)

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
            .padding(10)
        }
        .background(theme.surface)
    }

    private func runRow(_ run: RunRecord) -> some View {
        let active = model.loadedFileName == run.jsonURL.lastPathComponent
        let summary = model.runSummaries[run.jsonURL.path]
        return Button {
            model.loadRun(run)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(run.displayName)
                        .font(ThemeFont.title(11, weight: .semibold))
                        .foregroundStyle(theme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if active {
                        Text("当前")
                            .font(ThemeFont.micro(7.5))
                            .foregroundStyle(theme.signal)
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
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: ThemeMetrics.controlRadius)
                    .fill(active ? theme.surfaceSecondary : .clear)
            )
            .overlay(alignment: .leading) {
                if active {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(theme.signal)
                        .frame(width: 2)
                        .padding(.vertical, 7)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(run.jsonURL.path)
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
