import SwiftUI

@main
struct GeomagMacApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1_100, minHeight: 720)
                .preferredColorScheme(debugColorScheme)
        }
        .defaultSize(width: 1_440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开结果…") {
                    model.openResultFile()
                }
                .keyboardShortcut("o")
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("数据阶段") { model.go(to: .data) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("磁图阶段") { model.go(to: .map) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("运行阶段") { model.go(to: .run) }
                    .keyboardShortcut("3", modifiers: .command)
                Button("分析阶段") { model.go(to: .analysis) }
                    .keyboardShortcut("4", modifiers: .command)
                Divider()
                Button("开始计算") { model.runSelectedDataset() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("导出报告 PDF…") { model.exportReportPDF() }
                    .keyboardShortcut("e", modifiers: .command)
                Button("切换检查器") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        model.inspectorVisible.toggle()
                    }
                    if !model.inspectorVisible {
                        model.inspectorScrollTarget = nil
                    }
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
    }

    private var debugColorScheme: ColorScheme? {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["GEOMAG_APPEARANCE"] {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
        #else
        return nil
        #endif
    }
}
