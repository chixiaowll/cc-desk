import SwiftUI
import CCDeskCore

/// 设置 › 通用 › 外观里的主题选择（设计 §19）：某一档（浅色 / 深色）的所有主题，以迷你窗口缩略图平铺，点选即生效。
struct ThemePickerRow: View {
    let title: String
    let kind: TerminalColorScheme
    @ObservedObject private var themes = ThemeStore.shared

    private let columns = [GridItem(.adaptive(minimum: 76, maximum: 96), spacing: 8, alignment: .top)]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(ThemeCatalog.themes(kind)) { definition in
                    ThemeCard(id: definition.id, selected: themes.selectedID(kind) == definition.id) {
                        themes.select(definition.id)
                    }
                }
            }
        }
    }
}

/// 一个主题：缩略图 + 名称；选中时描一圈强调色。
private struct ThemeCard: View {
    @Environment(\.uiScale) private var uiScale
    let id: ThemeID
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var themes = ThemeStore.shared

    var body: some View {
        let current = themes.theme(for: colorScheme)
        let name = ThemeStore.name(id)
        Button(action: action) {
            VStack(spacing: 4) {
                ThemeThumbnail(theme: themes.theme(id))
                    .frame(width: 72, height: 46)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(selected ? current.accent : current.line, lineWidth: selected ? 2 : 1))
                Text(name)
                    .uiFont(size: 10, weight: selected ? .semibold : .regular)
                    .foregroundStyle(selected ? current.fg1 : current.fg2)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(width: uiScale.metric(80), height: uiScale.metric(26), alignment: .top)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 迷你窗口：左侧侧栏（几行条目，第一行带等待色状态点），右侧终端区（正文 / 强调色行与三种状态色点）。
struct ThemeThumbnail: View {
    let theme: Theme

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 2) {
                    Circle().fill(theme.pillWaitBg).frame(width: 4, height: 4)
                    bar(theme.fg2, width: 12)
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: 2).fill(theme.sel))
                bar(theme.fg3, width: 14).padding(.leading, 2)
                bar(theme.fg3, width: 10).padding(.leading, 2)
                Spacer(minLength: 0)
            }
            .padding(.top, 5)
            .padding(.horizontal, 2)
            .frame(width: 24)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(theme.side)
            theme.line.frame(width: 1)
            VStack(alignment: .leading, spacing: 4) {
                bar(Color(nsColor: theme.terminal.foreground), width: 30)
                bar(theme.accent, width: 18)
                bar(Color(nsColor: theme.terminal.foreground).opacity(0.6), width: 24)
                HStack(spacing: 3) {
                    Circle().fill(theme.pillWaitBg)
                    Circle().fill(theme.dot)
                    Circle().fill(theme.unread)
                }
                .frame(height: 5)
                Spacer(minLength: 0)
            }
            .padding(.top, 6)
            .padding(.leading, 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: theme.terminal.background))
        }
    }

    private func bar(_ color: Color, width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 1).fill(color).frame(width: width, height: 3)
    }
}

/// 菜单「显示 → 主题」：快速切换浅色 / 深色主题（与设置里的选择同步）。
struct ThemeMenu: View {
    @ObservedObject private var themes = ThemeStore.shared

    var body: some View {
        Menu(L("menu.theme")) {
            section(L("settings.general.lightTheme"), kind: .light)
            Divider()
            section(L("settings.general.darkTheme"), kind: .dark)
        }
    }

    private func section(_ title: String, kind: TerminalColorScheme) -> some View {
        Section(title) {
            ForEach(ThemeCatalog.themes(kind)) { definition in
                Toggle(ThemeStore.name(definition.id), isOn: Binding(
                    get: { themes.selectedID(kind) == definition.id },
                    set: { if $0 { themes.select(definition.id) } }))
            }
        }
    }
}
