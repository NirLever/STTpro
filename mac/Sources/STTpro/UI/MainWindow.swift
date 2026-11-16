import SwiftUI
import STTproCore

/// Which tab is shown and which settings card to scroll to.
@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var tab: MainTab = .settings
    @Published var scrollTarget: SettingsSection?
    @Published var failedHotkeys: [HotkeyBinding] = []
}

enum MainTab: String, CaseIterable { case settings = "Settings", history = "History" }

enum SettingsSection: String {
    case setup, providers, usage, audio, transcription, prompts, hotkeys, options
}

/// The Settings window: brand header + "Settings | History" tabs, like
/// src/STTpro.App/Views/SettingsWindow.xaml.
struct MainWindowView: View {
    @EnvironmentObject var nav: SettingsNavigation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                BrandTitle()
                Text("Speech to text, everywhere you type").font(.system(size: 12)).foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)

            TabBar(selection: $nav.tab)
                .padding(.horizontal, 16)
                .padding(.top, 12)

            Group {
                switch nav.tab {
                case .settings: SettingsPage()
                case .history: HistoryPage(showsTitle: false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bgPrimary)
        .tint(Theme.accentBlue)
    }
}

/// Windows TabControl look: text tabs with a 2pt accent underline.
private struct TabBar: View {
    @Binding var selection: MainTab
    @Namespace private var underline

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(MainTab.allCases, id: \.self) { tab in
                    Button { withAnimation(.easeOut(duration: 0.18)) { selection = tab } } label: {
                        VStack(spacing: 8) {
                            Text(tab.rawValue)
                                .font(.system(size: 14, weight: selection == tab ? .semibold : .regular))
                                .foregroundStyle(selection == tab ? Theme.accentBlue : Theme.textSecondary)
                                .padding(.horizontal, 18)
                            ZStack {
                                Rectangle().fill(Color.clear).frame(height: 2)
                                if selection == tab {
                                    Rectangle().fill(Theme.accentBlue).frame(height: 2)
                                        .matchedGeometryEffect(id: "underline", in: underline)
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                }
                Spacer()
            }
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }
}
