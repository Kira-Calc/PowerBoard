# AI Electricity 开发规格

版本 0.2，2026-10-12（0.2：重写第 10 节洁净度）
状态：可以开始开发
项目名为临时名称，见第 2 节"可替换的标识"。

---

## 1. 产品概述

一个 macOS 原生应用，读取本机 AI 编程工具（Claude Code、Codex）留下的日志，统计 token 用量，换算成服务端推理的估算耗电量、碳排放和日常等效对比，并在三个位置显示：

1. 菜单栏（iStat Menus 式，可定制）
2. 刘海区域的常驻面板（灵动岛式，可关闭）
3. Claude Code 的终端状态栏

另有一个操作台窗口，提供实时概览、明细、日报 / 周报 / 月报 / 年度总结，以及导出功能。

### 1.1 设计原则

- 所有能耗和碳排都是估算值。界面上每个估算数字都能查到计算方法、系数来源和不确定区间。不显示比数据本身更精确的数字。
- 完全本地运行。除可选的电网数据 API 外不发起任何网络请求，没有遥测，没有账号。
- 只读日志，不写入任何 AI 工具的配置。唯一的例外是用户在设置里主动开启"Claude Code 状态栏"时修改 `~/.claude/settings.json`，见第 8 节。
- 遵循 Apple Human Interface Guidelines，使用系统字体、系统颜色和标准控件。

### 1.2 不在范围内

- claude.ai 网页版和 Claude 桌面应用的普通聊天。它们不在本地写 token 日志，无法统计。界面和 README 中需说明这一点。
- 本机电脑自身的耗电。
- 费用（美元）统计。已有很多工具做这件事，本产品不重复。
- Windows 和 Linux。

---

## 2. 技术基线

| 项目 | 选择 |
|---|---|
| 最低系统 | macOS 14 Sonoma |
| 语言 | Swift 5.10+，开启严格并发检查 |
| UI | SwiftUI 为主；菜单栏用 AppKit `NSStatusItem` |
| 项目生成 | XcodeGen（`project.yml` 入库，`.xcodeproj` 不入库） |
| 数据库 | SQLite，通过 GRDB.swift |
| 图表 | Swift Charts |
| 刘海面板 | DynamicNotchKit |
| 命令行参数 | swift-argument-parser |
| 图标 | Phosphor Icons（矢量，作为模板图像放入 Asset Catalog），见第 11 节 |
| 本地化 | 简体中文、英文 |
| 开机启动 | `SMAppService.mainApp` |
| 许可证 | MIT |

### 2.1 第三方依赖与许可证

只允许使用 MIT、BSD、Apache-2.0 等宽松许可证的依赖。引入任何新依赖前，先确认其许可证，并记录到 `THIRD_PARTY_NOTICES.md`。

| 名称 | 用途 | 许可证 | 使用方式 |
|---|---|---|---|
| GRDB.swift | SQLite | MIT | SPM 依赖 |
| DynamicNotchKit | 刘海面板 | MIT | SPM 依赖，固定到 1.x |
| swift-argument-parser | CLI | Apache-2.0 | SPM 依赖 |
| Phosphor Icons | 图标 | MIT | 只复制用到的 SVG，不引入整个包 |
| claude-carbon | 能耗系数与方法 | MIT | 只移植系数和方法说明，不复制 bash 代码 |
| ccusage | Claude Code 日志解析思路 | MIT | 仅作参考 |

以下项目只能作为交互参考，不复制任何代码、素材、声音或文案：

- Vibe Island：闭源商业软件。
- Claude Island、AgentNotch、boring.notch 等：使用前必须先查看其许可证。如果是 GPL 类许可证，只能看思路，不能复制代码。

### 2.2 可替换的标识

产品名、Bundle ID、CLI 命令名、数据目录名都只在一个地方定义，方便以后改名：

- `project.yml` 中的 `PRODUCT_NAME`、`PRODUCT_BUNDLE_IDENTIFIER`
- `ElectricityCore/Sources/ElectricityCore/AppIdentity.swift`

```swift
public enum AppIdentity {
    public static let displayName = "AI Electricity"      // 临时
    public static let bundleID = "dev.placeholder.aielectricity" // 临时
    public static let cliName = "aie"                       // 临时
    public static let supportDirName = "AIElectricity"     // 临时
}
```

其他代码一律引用这些常量，不写死字符串。

---

## 3. 仓库结构

```
AI_Electricity/
├── CLAUDE.md
├── README.md                  (中英双语，M8 完成)
├── LICENSE                    (MIT)
├── THIRD_PARTY_NOTICES.md
├── project.yml                (XcodeGen)
├── docs/
│   ├── SPEC.md                (本文件)
│   ├── METHODOLOGY.md         (计算方法，中英双语)
│   └── DECISIONS.md           (开发中的决策记录)
├── Packages/
│   └── ElectricityCore/       (本地 Swift Package，App 和 CLI 共用)
│       ├── Package.swift
│       ├── Sources/ElectricityCore/
│       │   ├── AppIdentity.swift
│       │   ├── Sources/       (日志解析：ClaudeCode/, Codex/)
│       │   ├── Store/         (GRDB 数据库、迁移、查询)
│       │   ├── Energy/        (能耗模型、系数加载)
│       │   ├── Grid/          (电网强度：静态表 + 可选 API)
│       │   ├── Equivalents/   (等效换算)
│       │   ├── Reports/       (周期聚合)
│       │   ├── Snapshot/      (快照文件读写)
│       │   └── Localization/  (CLI 用的简单字符串表)
│       ├── Resources/
│       │   ├── energy-factors.json
│       │   ├── model-tiers.json
│       │   ├── grid-regions.json
│       │   └── equivalents.json
│       └── Tests/ElectricityCoreTests/
│           └── Fixtures/      (脱敏后的示例 JSONL)
├── App/
│   ├── Sources/
│   │   ├── AppMain.swift
│   │   ├── MenuBar/
│   │   ├── Island/
│   │   ├── Dashboard/
│   │   ├── Settings/
│   │   └── Export/
│   ├── Resources/
│   │   ├── Assets.xcassets    (含 Phosphor 图标)
│   │   └── Localizable.xcstrings
│   └── Info.plist
└── CLI/
    └── Sources/main.swift
```

`ElectricityCore` 必须能用 `swift build` 和 `swift test` 独立构建和测试，不依赖 Xcode 界面。

---

## 4. 数据采集

### 4.1 Claude Code

日志位置，按顺序全部扫描：

1. 环境变量 `CLAUDE_CONFIG_DIR` 下的 `projects/`（可能是逗号分隔的多个路径）
2. `~/.claude/projects/`
3. `~/.config/claude/projects/`

递归查找所有 `*.jsonl`，包括子代理（subagent）的日志文件。

每行一个 JSON 对象。只处理 `type == "assistant"` 且存在 `message.usage` 的行。需要的字段：

| 字段 | 用途 |
|---|---|
| `timestamp` | 时间（ISO 8601，UTC） |
| `sessionId` | 会话 ID |
| `cwd` | 项目路径 |
| `message.id` | 去重 |
| `requestId` | 去重 |
| `message.model` | 模型 |
| `message.usage.input_tokens` | 输入 |
| `message.usage.output_tokens` | 输出 |
| `message.usage.cache_creation_input_tokens` | 缓存写入 |
| `message.usage.cache_read_input_tokens` | 缓存读取 |

去重：
- 同一次 API 响应可能被写成多行，恢复会话（resume）时历史消息也会被复制到新文件。
- 去重键为 `message.id + ":" + requestId`，在全局范围内唯一。缺失其中任一字段时，用该行原文的 SHA-256 作为去重键。
- 数据库对去重键建唯一索引，插入时冲突即忽略。

`model` 为 `<synthetic>` 或用量全为 0 的行忽略。

### 4.2 Codex

日志位置：

1. 环境变量 `CODEX_HOME` 下的 `sessions/`
2. `~/.codex/sessions/`

文件为 `sessions/YYYY/MM/DD/rollout-*.jsonl`。CLI、IDE 扩展和 Codex 桌面版共用这个目录。

需要处理的行：

- `type == "session_meta"`：取会话 ID 和 `cwd`。
- `type == "turn_context"`：取当前模型 `payload.model`，作用于其后的 token 事件。
- `type == "event_msg"` 且 `payload.type == "token_count"`：取 `payload.info.last_token_usage`，这是单轮增量。不要使用 `total_token_usage` 相加，那是累计值。

`last_token_usage` 中的字段：`input_tokens`、`cached_input_tokens`、`output_tokens`、`reasoning_output_tokens`。

注意：
- `cached_input_tokens` 是 `input_tokens` 的子集。未缓存输入 = `input_tokens - cached_input_tokens`。
- `reasoning_output_tokens` 是否已包含在 `output_tokens` 里，必须用本机真实日志核实后再决定计算方式，并把结论写进 `docs/DECISIONS.md`。目标是每个 token 只计算一次。
- 去重键：文件路径 + 行号 + 时间戳的哈希。
- 字段名可能随 Codex 版本变化。解析器遇到未知结构时跳过该行并计数，不得崩溃。数据源页面显示跳过的行数。

### 4.3 增量读取

- 用 FSEvents 监听上述目录（递归）。另外每 60 秒做一次兜底扫描。
- 表 `file_cursor` 记录每个文件的 inode、已读字节偏移、修改时间。
- 只读取到最后一个换行符为止，不完整的末行留到下次。
- 如果文件大小小于记录的偏移，或 inode 改变，从头重读。去重机制保证不会重复计数。
- 首次启动时回填所有历史日志，在后台进行，界面显示进度。
- 解析在后台 actor 中进行，不阻塞主线程。

### 4.4 时间

- 数据库一律存 UTC。
- "今天""本周"等按用户本地时区计算。
- 周的起始日跟随系统设置（`Calendar.current.firstWeekday`）。

---

## 5. 能耗与碳排模型

### 5.1 公式

对每条用量记录：

```
有效输入 = 未缓存输入 + 缓存写入 × k_cache_write + 缓存读取 × k_cache_read
能耗 Wh  = 有效输入 / 1e6 × E_in(tier) + 输出 / 1e6 × E_out(tier)
碳排 g   = 能耗 Wh / 1000 × 电网碳强度 (gCO2e/kWh)
```

默认 `k_cache_write = 1.0`，`k_cache_read = 0.0`（与 claude-carbon 一致：缓存读取量很大，但能耗可以忽略）。两个值都可以在设置中修改。

每条记录同时计算低、中、高三个值。低值 = 中值 × `uncertainty.low`，高值 = 中值 × `uncertainty.high`。

### 5.2 系数（`energy-factors.json`）

中值由 claude-carbon 的碳系数（gCO2e/Mtok）除以其采用的 AWS 平均碳强度 0.287 kgCO2e/kWh 反推得到。claude-carbon 的 Sonnet 数据来自 Jegham et al. 2025 的实测，Opus 和 Haiku 为外推。

```json
{
  "version": "2026.10-1",
  "unit": "Wh per million tokens",
  "source": "Derived from claude-carbon (MIT) emission factors / 0.287 kgCO2e/kWh. Sonnet measured (Jegham et al. 2025), others extrapolated.",
  "uncertainty": { "low": 0.5, "high": 2.0 },
  "tiers": {
    "small":  { "input": 330,  "output": 1990 },
    "medium": { "input": 660,  "output": 3970 },
    "large":  { "input": 1740, "output": 10450 }
  }
}
```

不确定区间（×0.5 到 ×2）是临时设定，需在 `docs/METHODOLOGY.md` 中明确标注为假设。

### 5.3 模型分级（`model-tiers.json`）

按模型名匹配，从上到下取第一个命中的规则：

```json
{
  "rules": [
    { "match": "opus",   "tier": "large",  "confidence": "extrapolated" },
    { "match": "mythos", "tier": "large",  "confidence": "assumed" },
    { "match": "fable",  "tier": "large",  "confidence": "assumed" },
    { "match": "sonnet", "tier": "medium", "confidence": "measured" },
    { "match": "haiku",  "tier": "small",  "confidence": "extrapolated" },
    { "match": "mini",   "tier": "small",  "confidence": "assumed" },
    { "match": "gpt",    "tier": "medium", "confidence": "assumed" },
    { "match": "codex",  "tier": "medium", "confidence": "assumed" }
  ],
  "fallback": { "tier": "medium", "confidence": "unmapped" }
}
```

匹配不区分大小写。`confidence` 在界面中显示为可信度标签。命中 `fallback` 的模型在明细页单独列出，提示用户该模型没有对应系数。

### 5.4 电网碳强度

M1 至 M6 阶段使用固定值：

- 默认 287 gCO2e/kWh，口径标注为"云服务商电网平均值（AWS）"，与 claude-carbon 一致。
- 用户可以在设置中修改。

洁净度相关功能在 M7 实现，见第 10 节。

### 5.5 记录计算上下文

每条用量记录必须保存计算当时使用的系数版本、电网碳强度及其口径。原因：

- 系数以后会更新，旧数据需要能按新系数重算。
- 实时电网数据过后无法再取得，不保存就丢失了。

设置中提供"按当前系数重新计算全部历史"的按钮，执行前给出确认对话框。

---

## 6. 数据库

使用 GRDB，带版本化迁移。数据库文件位于 `~/Library/Application Support/<supportDirName>/data.sqlite`。

### 6.1 表结构

`usage_event`

| 列 | 类型 | 说明 |
|---|---|---|
| id | INTEGER PK | |
| dedupe_key | TEXT UNIQUE | 见第 4 节 |
| source | TEXT | `claude_code` / `codex` |
| session_id | TEXT | |
| project_path | TEXT | 可为空 |
| model | TEXT | |
| tier | TEXT | |
| tier_confidence | TEXT | |
| ts_utc | INTEGER | Unix 毫秒 |
| input_uncached | INTEGER | |
| cache_write | INTEGER | |
| cache_read | INTEGER | |
| output | INTEGER | |
| reasoning | INTEGER | 仅用于展示，不重复计入能耗 |
| factor_version | TEXT | |
| grid_g_per_kwh | REAL | |
| grid_basis | TEXT | `cloud_average` / `region_static` / `region_live` |
| grid_region | TEXT | 可为空 |
| clean_share | REAL | 0 到 1，可为空 |
| clean_level | TEXT | `cleaner` / `typical` / `lessClean`，可为空（M7） |
| grid_source | TEXT | `watttime` / `electricitymaps` / `static`，可为空（M7） |
| energy_wh_low | REAL | |
| energy_wh_mid | REAL | |
| energy_wh_high | REAL | |
| co2_g_mid | REAL | |

索引：`ts_utc`、`(source, ts_utc)`、`session_id`。

`file_cursor`：`path` PK、`inode`、`offset`、`mtime`、`skipped_lines`。

`settings` 不存数据库，用 `UserDefaults`。

### 6.2 保留

默认永久保留。设置中可以选择保留 1 年、2 年或永久，以及"清除全部数据"（需要确认）。

---

## 7. 快照文件

供菜单栏、刘海面板和 CLI 读取的轻量数据。由 App 在数据变化后写出，最多每秒一次。

路径：`~/Library/Application Support/<supportDirName>/snapshot.json`

写入方式：先写临时文件，再原子替换，避免读取到半个文件。

```json
{
  "schema": 1,
  "generated_at": "2026-10-12T02:15:30Z",
  "app_running": true,
  "today": {
    "date": "2026-10-12",
    "tokens": { "input": 0, "output": 0, "cache_write": 0, "cache_read": 0 },
    "energy_wh": { "low": 0, "mid": 0, "high": 0 },
    "co2_g": 0,
    "clean_share": null,
    "by_source": { "claude_code": { "energy_wh_mid": 0 }, "codex": { "energy_wh_mid": 0 } }
  },
  "sessions": {
    "<session_id>": {
      "source": "claude_code",
      "energy_wh_mid": 0,
      "co2_g": 0,
      "tokens_total": 0,
      "last_ts": "2026-10-12T02:15:10Z"
    }
  },
  "last_hour_sparkline_wh": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
}
```

`sessions` 只保留最近 24 小时内活跃的会话。

---

## 8. 三个显示层

三个显示层共用快照数据，可在设置中分别开关。显示模式选项：仅菜单栏、仅刘海面板、两者都显示。

### 8.1 菜单栏（iStat Menus 式）

使用 `NSStatusItem` 和自定义视图。应用为 `LSUIElement`（不显示 Dock 图标）；操作台窗口打开时临时切换为常规应用，关闭后恢复。

用户可以设置：

- 拆分方式：合并为一个状态项，或拆成多个独立状态项（电量、token、碳排各一个）。
- 每个状态项的显示内容：仅图标、图标加数字、仅数字、迷你曲线（最近 1 小时）。
- 数字的单位和小数位：自动，或固定为 Wh / kWh。

点击状态项弹出面板（`NSPopover` 内嵌 SwiftUI），内容：

- 今日电量（中值和区间）、token、碳排
- 1 到 2 个等效对比
- 按工具拆分的小条形图
- 按钮：打开操作台、设置、退出

规范：
- 状态栏图标为单色模板图像，高度约 16pt，自动适配浅色和深色菜单栏。
- 实时变化的数字使用等宽数字（`.monospacedDigit()`），避免数字变化时宽度跳动。
- 状态项宽度设上限，防止挤占其他菜单栏图标。

### 8.2 刘海面板

基于 DynamicNotchKit。

- 收起状态：显示今日电量和一个表示洁净度的小圆点（M7 前显示为中性灰色）。
- 悬停展开：显示和菜单栏弹出面板相同的核心数据。
- 没有刘海的屏幕（外接显示器、旧款 Mac）：显示为屏幕顶部居中的紧凑悬浮条。
- 设置项：常驻显示、空闲时自动隐藏（无新用量满 N 秒）、全屏时隐藏、悬停展开延迟。
- 遵守"减弱动态效果"系统设置，开启时用淡入淡出代替弹性动画。
- 面板为不激活窗口，不抢夺焦点。

### 8.3 Claude Code 终端状态栏

CLI 工具 `aie`（名称来自 `AppIdentity.cliName`），内置于 App 包：`<App>.app/Contents/Helpers/aie`。

命令：

```
aie statusline [--lang en|zh] [--format default|compact] [--chain "<command>"]
aie today [--json] [--lang en|zh]
aie report --period day|week|month|year [--date YYYY-MM-DD] [--format md|json|csv]
aie install-statusline
aie uninstall-statusline
```

`aie statusline` 行为：

1. 从 stdin 读取 Claude Code 传入的 JSON，取 `session_id`。
2. 读取快照文件，查找该会话和今日数据。
3. 输出一行文字，必须在 50ms 内完成。

默认英文输出。示例：

```
82 Wh session | 1.24 kWh today | 356 g CO2e
```

`--lang zh`：

```
本会话 82 Wh | 今日 1.24 kWh | 356 g CO2e
```

`compact` 格式：

```
1.24 kWh | 356 g
```

规则：
- 不输出 emoji。可以使用 ANSI 颜色，检测到 `NO_COLOR` 环境变量时不输出颜色。
- App 未运行或快照超过 5 分钟未更新时，显示最后的数值并在末尾加 `(stale)` / `（未更新）`。
- 快照不存在时，输出 `aie: open the app to start tracking`，不报错退出（退出码 0）。
- 语言优先级：`--lang` 参数 > 应用设置中的"CLI 语言" > 默认英文。

安装（`aie install-statusline`，以及设置里的开关调用同一逻辑）：

1. 读取 `~/.claude/settings.json`。不存在则创建。
2. 备份为 `settings.json.aie-backup-<时间戳>`。
3. 如果已存在 `statusLine` 配置，询问用户（在 App 中用对话框，在 CLI 中用交互提示）：替换，或组合。组合模式使用 `--chain`：先运行原命令，再把本工具的输出接在后面，中间用 ` | ` 分隔。
4. 只修改 `statusLine` 字段，保留文件中其他所有内容和格式。
5. 卸载时恢复原有配置。

Codex 当前只支持内置的状态栏字段，不支持外部命令。README 中提供两种替代方案的配置示例：tmux 的 `status-right`，以及 iTerm2 状态栏组件。代码中把"生成状态文字"和"接入方式"分开，以便将来 Codex 支持外部命令时只需增加适配。

---

## 9. 操作台窗口

一个窗口，`NavigationSplitView` 侧边栏布局，与系统设置的样式一致。`⌘,` 直接打开到设置部分。

侧边栏分组（分组标题为普通文字，不用全大写）：

```
数据
  实时概览
  报告
  明细
  洁净度
设置
  通用
  数据源
  显示
  计算方法
  通知
关于
  方法说明
  关于与致谢
```

### 9.1 实时概览

- 今日电量：中值大字显示，下方小字显示区间。
- token：输入、输出、缓存写入、缓存读取分开显示。附一句说明：缓存读取不计入能耗。
- 碳排：克数，注明口径。
- 等效对比：自动选 2 到 3 项，见 9.6。
- 今日每小时用电柱状图（Swift Charts）。
- 最近活跃的会话列表：工具、项目名、模型、本会话电量。
- 每个估算数字旁有信息按钮，点开显示计算过程和系数来源。

### 9.2 报告

- 周期切换：日、周、月、年。左右箭头切换上一期和下一期。
- 内容：总量、与上一期对比、按工具 / 模型 / 项目的拆分、趋势图、用量最高的时段。
- 导出按钮，见第 12 节。

年度总结单独设计为一组分页卡片，内容包括：全年总电量和等效、用量最高的一天、最常用的模型、最长的会话、各月变化。数据不足一年时按实际天数显示，并注明起始日期。

### 9.3 明细

可排序、可筛选的表格（`Table`）：按会话、项目、模型分组。列：时间、工具、模型、可信度、token、电量、碳排。

### 9.4 洁净度

M7 之前显示说明文字和当前使用的固定碳强度。M7 之后见第 10 节。

### 9.5 设置

通用
- 登录时打开
- App 语言：跟随系统 / 简体中文 / English
- CLI 语言：English（默认）/ 简体中文

数据源
- Claude Code、Codex 各一行：检测到的路径、状态（正常 / 未找到）、上次读取时间、已记录条数、跳过的行数。
- 添加自定义路径。
- 重新扫描。

显示
- 显示模式：仅菜单栏 / 仅刘海面板 / 两者
- 菜单栏：拆分方式、各项显示内容、单位
- 刘海面板：常驻、空闲隐藏及时长、全屏隐藏、悬停延迟
- 终端状态栏：开关（调用安装逻辑）、语言、格式

计算方法
- 当前系数版本和来源
- 缓存写入、缓存读取的计算比例
- 电网碳强度：数值和口径
- 按当前系数重新计算历史
- 等效对比：选择启用哪些项目

通知
- 每日报告提醒（时间可选）
- 每周报告提醒
- 今日用电超过设定值时提醒

关于
- 方法说明：内嵌 `METHODOLOGY.md` 的内容
- 版本、许可证、第三方声明（包括 claude-carbon 的 MIT 版权声明原文）

### 9.6 等效对比（`equivalents.json`）

分两类，含义不同，界面上要写清楚：

- 电器：这些电够某个电器用多久。
- 食物：这些电的能量相当于某种食物所含的热量。比较的是能量本身，不是生产食物的耗电。

```json
{
  "version": "2026.10-1",
  "note": "Reference values. Verify each source before release.",
  "items": [
    { "id": "microwave_minute", "kind": "appliance", "wh": 16.7, "basis": "1000 W microwave, 1 minute", "source": "" },
    { "id": "phone_charge",     "kind": "appliance", "wh": 15,   "basis": "one full smartphone charge", "source": "" },
    { "id": "kettle_boil",      "kind": "appliance", "wh": 100,  "basis": "boiling 1 L of water", "source": "" },
    { "id": "led_hour",         "kind": "appliance", "wh": 10,   "basis": "10 W LED bulb, 1 hour", "source": "" },
    { "id": "laptop_hour",      "kind": "appliance", "wh": 50,   "basis": "laptop under typical load, 1 hour", "source": "" },
    { "id": "banana",           "kind": "food",      "wh": 122,  "basis": "105 kcal x 1.163 Wh/kcal", "source": "" },
    { "id": "egg",              "kind": "food",      "wh": 87,   "basis": "75 kcal x 1.163 Wh/kcal", "source": "" },
    { "id": "rice_bowl",        "kind": "food",      "wh": 233,  "basis": "200 kcal x 1.163 Wh/kcal", "source": "" }
  ]
}
```

`source` 字段在发布前必须填写。每个条目还需要中英文名称和计数单位，放在 String Catalog 中，键为 `equivalent.<id>.name` 和 `equivalent.<id>.unit`。

自动选择规则：对每个已启用的条目计算 `count = 电量 / wh`，优先选 `count` 在 1 到 100 之间的条目，电器和食物各取一个，最多显示 3 个。显示时保留 1 位有效小数，`count < 1` 时改用时间或分数表达（如"约 20 秒微波炉"），不显示"0.0x 次"。

---

## 10. 洁净度（M7）

### 10.0 目标

参考 iOS 的"清洁能源充电"和"家庭"App 的"电网预测"：告诉用户此刻推理服务器所在电网是相对清洁还是相对不清洁。

只提供信息，不干预。不暂停、不延迟、不排队用户的任何任务，也不向用户建议推迟工作。

### 10.1 核心指标：相对清洁等级

主要显示的不是绝对的清洁电力百分比，而是"该电网此刻与它自身近期水平相比如何"，分三档：

| 等级 | 中文 | English |
|---|---|---|
| `cleaner` | 较清洁 | Cleaner |
| `typical` | 一般 | Typical |
| `lessClean` | 较不清洁 | Less clean |

理由：
- 这与 iOS 的表达方式一致，用户容易理解。
- 不同电网的绝对水平差异很大，相对等级更能反映"现在"这个时刻的变化。
- 数据更容易免费取得（见 10.3）。

绝对数值（清洁电力占比 %、gCO2e/kWh）作为次要信息，在展开面板和洁净度页面中显示，前提是数据源能提供。

### 10.2 推理地点

推理地点通常无法确定，按以下优先级处理：

1. 确定地点：日志中有明确区域信息（例如通过 Bedrock、Vertex 的区域端点调用）时，直接使用。
2. 推测地点：读取 `grid-regions.json` 中按服务商列出的候选区域和权重。

```json
{
  "version": "2026.10-1",
  "providers": {
    "anthropic": {
      "candidates": [
        { "region": "PLACEHOLDER_A", "watttime_region": "", "emaps_zone": "", "weight": 0.5, "note": "" },
        { "region": "PLACEHOLDER_B", "watttime_region": "", "emaps_zone": "", "weight": 0.5, "note": "" }
      ]
    },
    "openai": { "candidates": [] }
  }
}
```

候选区域和权重需要人工调研后填写，资料来源写在 `note` 中。开发阶段保留占位值，界面在此情况下显示"地点未知"，不显示等级。

多个候选区域时：
- 按权重加权得到综合等级。
- 各候选区域的等级不一致时，界面同时说明"各候选地区情况不同"，并在洁净度页面逐个列出。

### 10.3 数据源

按优先级：

1. WattTime（默认推荐）。其免费的 Basic 方案提供所有覆盖区域的 CO2 相对百分位数据，正好对应 10.1 的相对等级。用户在设置中填写自己的 WattTime 账号后启用。
   - 百分位到三档的映射默认为：清洁的 1/3、中间 1/3、不清洁的 1/3，阈值可在设置中调整。实现前先核实 WattTime 百分位的方向（数值越高代表越清洁还是越不清洁），写入 `DECISIONS.md`。
   - WattTime 的预测和历史接口在免费方案下只对少数区域开放，不能作为必需功能。
2. Electricity Maps（可选）。用户填入 API 密钥后，补充绝对数值（清洁电力占比、碳强度），在其方案支持时显示未来数小时的预测。
3. 静态回退。两者都未配置或请求失败时，使用 `grid-regions.json` 中各区域的年均值，只显示绝对数值的年均水平，不显示相对等级，并注明"未连接实时数据"。

通用规则：
- 每个区域每 15 分钟最多请求一次，结果缓存在本地。
- 请求失败时回退到上一次的缓存（标注时间）或静态值，不弹窗打扰用户。
- 账号密码和 API 密钥存入钥匙串，不存 `UserDefaults`。
- 每条 `usage_event` 记录写入时的等级、清洁占比和数据源（第 6 节的 `clean_level`、`clean_share`、`grid_source` 列）。

### 10.4 预测（可选）

当数据源能提供某区域的预测数据时，在洁净度页面显示未来 24 小时的等级时间轴，类似 iOS"家庭"App 的电网预测：横向时间轴，按时段着色，并用文字标出"较清洁"的时段。

预测只作为信息展示，不提供提醒、调度或推迟任务的功能。

### 10.5 显示

三个显示层的统一规则：
- 地点确定时用实心圆点，推测时用空心圆点。
- 等级同时用颜色和文字表达，不能只靠颜色区分。颜色使用系统颜色：`cleaner` 为绿色，`typical` 为中性色，`lessClean` 为橙色。不使用红色，避免带有"警告"或"错误"的含义。
- 未知时显示灰色空心圆点和"未知"。

各显示层：
- 菜单栏：电量数字旁显示圆点，悬停提示例如"服务器电网：较清洁（推测地点）"。
- 刘海面板：收起时显示圆点，展开时显示等级文字、地点和数据更新时间。
- 终端状态栏：在末尾增加一段文字，例如英文 `grid: cleaner (est.)`，中文 `电网：较清洁（推测）`。不配置数据源时不显示这一段。
- 洁净度页面：当前等级、各候选地区明细、绝对数值（如有）、预测时间轴（如有）、今日用电中各等级时段分别占多少电量。

快照文件（第 7 节）的 `today` 中增加：

```json
"grid": {
  "level": "cleaner",
  "location_certainty": "estimated",
  "clean_share": null,
  "updated_at": "2026-10-12T02:10:00Z",
  "source": "watttime"
}
```

---

## 11. 视觉、图标与文案

### 11.1 图标

- 统一使用 Phosphor Icons 的 Regular 字重；需要强调时用 Fill。不混用其他图标库，不使用 emoji，也不使用 SF Symbols（保持整个应用图标风格一致）。
- 只把用到的 SVG 从 Phosphor 官方仓库复制到 `Assets.xcassets`，设置为"Template Image"并勾选"Preserve Vector Data"。
- 在 `App/Sources/Icons.swift` 中集中定义图标名称常量，其他代码不直接写图标文件名。
- 建议的图标映射（实现时可以调整，但需在 `DECISIONS.md` 记录）：

| 用途 | Phosphor 图标 |
|---|---|
| 菜单栏主图标 / 电量 | `lightning` |
| token | `coins` 或 `hash` |
| 碳排 | `cloud` |
| 洁净度 | `leaf` |
| 实时概览 | `gauge` |
| 报告 | `calendar-blank` |
| 明细 | `table` |
| 通用设置 | `gear-six` |
| 数据源 | `folder-open` |
| 显示 | `monitor` |
| 计算方法 | `function` |
| 通知 | `bell` |
| 方法说明 | `book-open` |
| 关于 | `info` |
| 导出 | `export` |
| Claude Code / Codex 来源 | `terminal-window` |

- 侧边栏图标与系统设置一致：放在圆角色块里，白色图标。色块使用系统颜色（`.blue`、`.green`、`.orange` 等），不自定义渐变。
- 应用图标（App Icon）单独设计，不在本规格范围内。开发阶段用纯色占位。

### 11.2 视觉

- 字体：系统字体（SF Pro / 苹方）。不引入自定义字体。
- 颜色：系统语义颜色（`.primary`、`.secondary`、`Color.accentColor`），支持浅色、深色和"增强对比度"。
- 材质：弹出面板和刘海面板使用系统材质（`.regularMaterial` 等）。
- 不使用装饰性渐变、阴影堆叠或进入动画。只有响应用户操作的动画（展开、收起、切换）。
- 所有控件支持 VoiceOver，图标按钮必须有无障碍标签。
- 支持键盘操作。

### 11.3 文案

中英文都遵守：

- 用用户能理解的词描述，不描述系统内部实现。写"数据源"，不写"日志解析器"。
- 简短、直接、主动语态。按钮写具体动作："导出 PDF"，而不是"确定"。同一个操作在整个流程中名称一致。
- 不使用营销语气和夸张词。避免"强大""无缝""一站式""智能洞察""赋能"以及英文的 "seamless""powerful""unlock""supercharge" 等。
- 不使用 emoji、感叹号和装饰性符号。
- 估算值统一用"约"/"about"或"≈"，并在可以查看详情的地方提供区间。
- 错误提示说明发生了什么、怎么解决，不道歉。例如："没有找到 Claude Code 的日志。在数据源中添加路径，或运行一次 Claude Code。"
- 空状态告诉用户下一步做什么。例如："今天还没有用量。运行 Claude Code 或 Codex 后，这里会显示数据。"
- 英文界面使用句首大写（sentence case），不用全大写标签。

示例：

| 键 | 简体中文 | English |
|---|---|---|
| `overview.today.energy` | 今日用电 | Energy today |
| `overview.estimate.range` | 约 %@，区间 %@ 到 %@ | About %@, range %@ to %@ |
| `overview.cache.note` | 缓存读取不计入能耗 | Cache reads are not counted as energy use |
| `empty.today` | 今天还没有用量。运行 Claude Code 或 Codex 后，这里会显示数据。 | No usage yet today. Data appears here after you run Claude Code or Codex. |
| `export.pdf` | 导出 PDF | Export PDF |
| `source.notFound` | 没有找到日志 | No logs found |

---

## 12. 导出

| 格式 | 内容 | 实现 |
|---|---|---|
| PNG | 分享卡片，竖版 1080×1350 和横版 1600×900 | `ImageRenderer` |
| PDF | 完整报告，含图表和方法说明摘要 | `ImageRenderer` 渲染到 PDF 上下文，A4 |
| CSV | 原始 `usage_event` 记录 | 手写，UTF-8 带 BOM（便于 Excel 正确识别中文） |
| JSON | 原始记录和汇总 | `JSONEncoder` |
| Markdown | 文字版报告 | 模板字符串 |

- 导出语言跟随 App 语言，导出对话框中可以单独选择。
- PNG 和 PDF 的报告视图与应用内视图共用同一套 SwiftUI 组件。
- 每份 PNG / PDF 底部注明："估算值。方法见 <仓库地址>/docs/METHODOLOGY.md"。
- 自动导出（可选）：每日、每周、每月在指定时间生成，保存到用户选择的文件夹（通过安全书签保存文件夹权限）。

---

## 13. 隐私与安全

- 不读取日志中的对话内容，只读取第 4 节列出的字段。数据库中不保存任何提示词或回复文本。
- 项目路径默认只显示最后一级文件夹名。完整路径仅在明细页悬停时显示。
- 导出时提供"隐藏项目名"选项。
- 唯一的网络请求是可选的电网 API。

---

## 14. 测试

`ElectricityCore` 的单元测试必须覆盖：

- Claude Code 解析：正常行、重复行（同 `message.id` + `requestId`）、恢复会话导致的跨文件重复、`<synthetic>` 模型、缺字段、损坏的 JSON 行、不完整的末行。
- Codex 解析：`turn_context` 切换模型、`last_token_usage` 增量、缓存子集计算、未知事件类型。
- 增量读取：追加、截断、inode 变化。
- 能耗计算：每个 tier 的已知输入输出，三个不确定值，缓存比例设置生效。
- 模型分级：每条规则、大小写、fallback。
- 等效选择：边界值（`count` 恰为 1 和 100、小于 1、极大值）。
- 时间：跨午夜、跨时区、周起始日。
- 快照：原子写入，读取方在写入过程中不会读到损坏文件。
- CLI：`statusline` 在快照缺失、过期、正常三种情况的输出，中英文。

测试用的 JSONL 示例放在 `Tests/.../Fixtures/`，必须是手写或彻底脱敏的数据，不能包含真实对话内容或真实路径。

---

## 15. 里程碑

每个里程碑完成后：所有测试通过，`xcodebuild` 构建成功，更新 `docs/DECISIONS.md`，提交一次 git commit。

| 里程碑 | 内容 | 验收标准 |
|---|---|---|
| M0 脚手架 | 仓库结构、`project.yml`、Core 包、空 App 和 CLI 目标、LICENSE、THIRD_PARTY_NOTICES | `xcodegen` 生成项目；App 启动后菜单栏出现占位图标；`swift test` 运行 |
| M1 数据核心 | 两个解析器、增量读取、数据库与迁移、能耗计算、回填 | 测试全部通过；对本机真实日志运行后，token 总数与 ccusage 的结果偏差在 1% 以内（仅 Claude Code 部分） |
| M2 菜单栏 | `NSStatusItem`、弹出面板、快照写出、基础设置 | 用 Claude Code 对话时，菜单栏数字在 2 秒内更新 |
| M3 操作台 | 窗口框架、实时概览、明细、设置各页 | 所有设置项可用并在重启后保留 |
| M4 终端状态栏 | `aie` CLI、安装 / 卸载 / 组合 | 在 Claude Code 中显示；原有 statusLine 能正确组合和恢复；执行时间小于 50ms |
| M5 报告与导出 | 四种周期、年度总结、五种导出格式、自动导出 | 每种格式在中英文下都能正确打开 |
| M6 刘海面板 | DynamicNotchKit 集成、无刘海屏幕降级、相关设置 | 在有刘海和外接显示器上都正常；减弱动态效果时无弹性动画 |
| M7 洁净度 | 区域表、WattTime 相对等级、可选 Electricity Maps、静态回退、三个显示层的等级显示 | 能正确显示三档等级；API 不可用时自动回退；密钥存在钥匙串中；不含任何暂停或推迟任务的功能 |
| M8 收尾 | 本地化检查、无障碍检查、README、METHODOLOGY、发布包 | 所有界面字符串在两种语言下都有翻译；VoiceOver 可完成主要操作；README 包含未签名应用的安装说明 |

### 15.1 发布（M8）

- 暂不进行 Apple 开发者签名和公证。用临时签名（ad-hoc）构建。
- 提供 `scripts/build-release.sh`：构建 Release，打包为 zip。
- README 中说明两种安装方式：从源码构建；下载 zip 后在"系统设置 > 隐私与安全性"中选择"仍要打开"，或运行 `xattr -dr com.apple.quarantine <App路径>`。

---

## 16. 待定事项

开发不需要等这些确定，先用占位值：

- 正式产品名、Bundle ID、CLI 命令名
- 能耗系数的不确定区间
- Codex 所用模型的分级
- `grid-regions.json` 的候选区域和权重
- `equivalents.json` 每项的数据来源
- 应用图标设计
