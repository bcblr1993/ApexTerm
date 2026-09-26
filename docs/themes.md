# ApexTerm 主题

设置 → 终端 → 全局主题。经典白色为首次使用和恢复默认时的主题；升级首次启用全局主题时也使用经典白色，旧终端配色的存储键保留；旧预设的名称和色板继续兼容。

预设包括经典白色、VS Code Dark Modern、Tokyo Night、Catppuccin Mocha、Nord、Dracula、Catppuccin Latte、One Dark Pro、Gruvbox Dark、Everforest、Rosé Pine、Solarized Light。

主题覆盖文字、状态、侧栏、工作区、弹窗、按钮强调色、终端、光标、查找栏和文本选区。原生菜单、列表、输入框、分段控件使用相应的 macOS 浅色或深色外观。

UI 文字及状态色在实际主题表面上至少保持 4.5:1 对比度。不足时保留色相并调整明度。ANSI 的 16 个索引色随主题切换；终端已显示的默认色和索引色同步刷新，应用主动指定的 TrueColor RGB 及 256 色扩展值保持原样。无需断开 SSH。

## 配色来源

界面层级为 ApexTerm 适配；核心色板参考以下项目（未捆绑这些工具）：

- [VS Code / Microsoft](https://github.com/microsoft/vscode/tree/main/extensions/theme-defaults/themes)
- [Tokyo Night / Folke Lemaitre](https://github.com/folke/tokyonight.nvim)
- [Catppuccin](https://github.com/catppuccin/kitty)
- [Nord / Arctic Ice Studio](https://www.nordtheme.com/)
- [Dracula](https://github.com/dracula/kitty)
- [One Dark Pro / Binaryify](https://github.com/Binaryify/OneDark-Pro)
- [Gruvbox / Pavel Pertsev](https://github.com/morhetz/gruvbox)
- [Everforest / sainnhe](https://github.com/sainnhe/everforest/blob/master/palette.md)
- [Rosé Pine](https://github.com/rose-pine/kitty)
- [Solarized / Ethan Schoonover](https://ethanschoonover.com/solarized/)

## 验证

`swift test --filter ThemeSupportTests` 检查所有主题的对比度、ANSI 索引及 TrueColor、历史输出切换。

`APEX_THEME_SNAPSHOTS=1 swift test --filter ThemeSupportTests` 额外渲染设置页、会话弹窗、关于和快捷键页面，输出到 `.build/theme-previews`。使用测试窗口，不替换已安装的应用。
