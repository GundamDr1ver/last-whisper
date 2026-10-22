# speakeasy SE 图标

黑色几何 SE 字形搭配白色圆角底。S 使用连续圆弧，E 使用斜切端点；不依赖字体、位图生成或外部设计工具。

- 应用图标矢量源：`Assets/AppIcon.svg`，1024 × 1024，圆角底外透明。
- 菜单栏矢量源：`Sources/VoiceInput/Resources/MenuBarIcon.svg`，同一 SE 字形，透明底，运行时适配系统深浅色。
- 使用 `swift Scripts/render-icon.swift` 生成 PNG 图标和菜单栏预览，再运行 `Scripts/build-app.sh` 生成各尺寸 ICNS。

资源使用项目内的 SVG 和 macOS AppKit 渲染；没有新增依赖，也没有修改录音、识别或润色逻辑。
