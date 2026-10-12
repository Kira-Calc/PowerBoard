<p align="center"><img src="docs/images/icon.png" width="128" alt="PowerBoard 图标"></p>

<h1 align="center">PowerBoard</h1>

<p align="center">AI 编程工具的信息面板：用量统计、会话管理，以及背后的耗电与碳排。</p>

<p align="center"><a href="README.en.md">English</a> · <a href="docs/METHODOLOGY.md">计算方法</a> · <a href="https://github.com/Kira-Calc/PowerBoard/releases">下载</a></p>

> **测试版（0.1.0）**。功能和数值模型仍可能调整。欢迎通过 Issues 反馈问题。

---

## 这是什么

PowerBoard 是一个 macOS 菜单栏应用，也是你本机 AI 编程工具的**信息面板**。它读取 Claude Code、Codex 和 Google Antigravity 在本机写下的日志，把分散在各个工具里的信息集中到一处：

- **用量统计**：每个工具、模型、项目和会话的 token 用量，按小时、天、周查看趋势，生成日 / 周 / 月 / 年报告并导出。
- **会话管理**：列出正在运行的对话及其状态，点击即可切换到对应的终端；任务完成时提醒你。
- **耗电与碳排**：根据公开研究中的能耗系数，估算服务商数据中心为这些请求消耗的电量和碳排，并显示服务器所在电网当前是否相对清洁。
- **终端状态栏**：在 Claude Code 底部直接显示今日用量和耗电。

PowerBoard 只显示你实际在用的工具。例如只用 Claude Code 的用户，界面上不会出现 Codex 和 Antigravity。

耗电和碳排都是**估算值，不是测量值**，并且始终以区间（低 / 中 / 高）表示。

## 为什么做这个

同时使用多个 AI 编程工具时，用量分散在各自的日志里：哪个工具、哪个项目用得最多，哪个对话还在运行，需要分别打开各个工具去看。PowerBoard 把这些信息放在菜单栏里，一眼就能看到。

另一方面，大语言模型推理的能耗正在变成一个不可忽视的量。国际能源署（IEA）预计，全球数据中心用电量到 2030 年将比 2024 年翻一番以上，AI 是主要的增长来源 [1]。de Vries 估算，在最极端的情形下（每次 Google 搜索都调用大语言模型），仅这一项的用电量就可能与爱尔兰全国相当 [2]。对单次推理的研究也表明，不同任务、模型和硬件之间的能耗差异可达数个数量级 [3][4][5]。

但对单个用户来说，这些数字既看不见，也难以理解。服务商通常不公开每次请求的能耗，也不公开请求在哪个数据中心处理。PowerBoard 的目标不是给出精确答案，而是：

- 让 AI 编程工具的用量和它背后的能耗变得**可见**；
- 用**有出处的系数**和**明确标注的假设**给出一个数量级上的参考；
- 把电量换算成日常能理解的单位，并提供服务器所在电网当前是否相对清洁的信息。

## 支持的工具

| 工具 | 读取的本地数据 | 状态 |
| --- | --- | --- |
| Claude Code | `~/.claude/projects/**/*.jsonl` | 支持，已与 ccusage 核对（偏差 0.035%） |
| Codex | `~/.codex/sessions/**/*.jsonl` | 支持 |
| Google Antigravity | `~/.gemini/antigravity*` 下的 SQLite | 支持，尚未用真实数据核对 |

**后续会支持更多 AI 编程工具。** 欢迎在 Issues 中告诉我们你在用的工具。

## 功能

| 位置 | 内容 |
| --- | --- |
| 菜单栏 | 今日推理耗电估算（或 token 数）；连接实时电网数据后，显示服务器电网等级圆点 |
| 弹出面板 | 电量、碳排、token、日常换算（随机轮换）、活跃对话（点击跳转到对应终端）、各工具合计 |
| 操作台 | 实时概览和图表、日 / 周 / 月 / 年报告与年度总结、逐条明细、电网洁净度、设置 |
| Claude Code 状态栏 | 通过随附的 `powerboard` 命令，在 Claude Code 底部显示今日电量和碳排 |
| 导出 | CSV、JSON、Markdown、PNG、PDF；可手动导出，也可按日 / 周 / 月自动导出 |

**不统计**：claude.ai 网页版和 Claude 桌面应用中的聊天。它们不在本机写入 token 日志。

## 估算方法

完整说明见 [docs/METHODOLOGY.md](docs/METHODOLOGY.md)，这里只列出要点。

### 电量

```
有效输入 = 未缓存输入 + 缓存写入 × k_write + 缓存读取 × k_read
电量 (Wh) = 有效输入 / 10⁶ × E_in(档位) + 输出 / 10⁶ × E_out(档位)
```

- **系数来源**：采用 claude-carbon [6] 的碳排系数（commit `d7313ff`），除以其假设的电网碳强度 0.287 kgCO₂e/kWh，反推为 Wh/百万 token。claude-carbon 的中档系数拟合自 Jegham 等人对 Claude Sonnet 的推理能耗基准测试 [3]，已包含数据中心 PUE 1.14。
- **档位**：小 70 / 1,439，中 136 / 2,878，大 272 / 5,756，特大 544 / 11,512（输入 / 输出，Wh/百万 token）。只有中档有实测依据，其余档位按 0.5 倍或 2 倍外推。
- **缓存**：缓存写入按输入的 1.0 倍计，缓存读取按 0.08 倍计（与 claude-carbon 一致），都可以在设置中修改。
- **模型分级**：按模型名匹配档位，每条规则都标注了可信度（实测、外推、假设、未匹配）。OpenAI 和 Google 的模型目前没有公开的实测系数，只能按"假设"处理。

### 区间

每个估算值都有低、中、高三个值：低值 = 中值 × 0.5，高值 = 中值 × 2。

**这个区间是人为设定的假设，不是统计意义上的置信区间。** 已发表的研究表明，同一模型的单次推理能耗会随硬件、批大小、输出长度和数据中心而变化，变化幅度往往超过这个区间 [3][4][5]。设置区间的目的，是提醒读者不要把中值当作精确结果。

### 碳排

```
碳排 (g) = 电量 (Wh) / 1000 × 电网碳强度 (gCO₂e/kWh)
```

默认碳强度为 287 gCO₂e/kWh，即 claude-carbon 采用的 AWS 平均值，可以在设置中修改。

### 电网洁净度

服务商不公开每个请求在哪个数据中心处理。PowerBoard 为每家服务商选取 3 到 5 个根据公开报道推测的候选地点，并赋予权重；所有地点都标记为"推测"。

| 数据 | 需要账号 | 说明 |
| --- | --- | --- |
| WattTime `signal-index` [8] | 是（免费） | 0 到 100 的百分位，比较各电网此刻与其未来 24 小时的预测。这是相对指标，不同电网之间不能直接比较。 |
| 美国 EIA 小时电网监测（EIA-930）[9] | 否 | 最近发布的 24 小时内的清洁电力占比（太阳能、风电、水电、核电、地热）。通常晚一天左右发布，不代表此刻。 |
| 美国 EPA eGRID2023 [10] | 否 | 各子区域的年均排放率，作为回退值。 |
| Electricity Maps [11] | 是（可选） | 补充实时碳强度和清洁电力占比。 |

洁净度只提供信息，PowerBoard 不会暂停、推迟或安排你的任何任务。碳排估算始终使用上面的固定碳强度，不随电网等级变化。

### 日常换算

为了让电量更直观，PowerBoard 会把它换算成日常事物，并在你启用的项目中随机轮换显示。每一项都有出处：

| 项目 | 每单位 Wh | 依据 |
| --- | ---: | --- |
| 微波炉（1000 W）1 分钟 | 16.7 | 按定义计算 |
| 吹风机（1500 W）1 分钟 | 25 | 按定义计算 |
| 烧开 1 L 水 | 92.9 | 从 20 °C 加热到 100 °C 所需热量，不计热损失，是下限 |
| LED 灯泡（10 W）1 小时 | 10 | 按定义计算 |
| 笔记本电脑（50 W）1 小时 | 50 | 假设的常见负载 |
| 给手机充满一次电 | 19 | 美国 EPA [12] |
| Gemini 文本提问 1 次 | 0.24 | Google 公布的中位数 [13] |
| ChatGPT 提问 1 次 | 0.34 | OpenAI CEO 的自述平均值，未公开方法 [14] |
| 在线看视频 1 小时 | 77 | IEA 对 2019 年 Netflix 的估算 [15] |
| 美国家庭平均 1 天 | 33,408 | 美国 EIA 2022 年数据，经 EPA 引用 [12] |
| 香蕉（126 g） | 130.3 | USDA FoodData Central [16] |
| 鸡蛋（大号，50 g） | 83.1 | USDA FoodData Central [16] |
| 一碗米饭（158 g） | 238.7 | USDA FoodData Central [16] |
| 汉堡（麦当劳 Hamburger） | 290.6 | 麦当劳美国官方营养数据，250 kcal |
| 巨无霸 | 674.1 | 麦当劳美国官方营养数据，580 kcal |
| 罐装可乐（355 mL） | 162.7 | 可口可乐美国官方数据，140 kcal |

食物热量按 1 kcal = 4.184 kJ = 1.1622 Wh 换算。食物项只是把电能和食物热量放在一起比较大小，两者不是同一种能量。

## 局限性

- **系数的外推**：只有 Claude Sonnet 一档有基准测试依据 [3]，其余档位和非 Anthropic 模型的系数都是外推或假设。
- **地点的推测**：服务器地点不公开，候选地点和权重来自新闻报道，可能与实际情况相差很大。
- **范围**：不包括网络传输、终端设备、模型训练和硬件制造的隐含排放。相关讨论见 [7]。
- **服务商自述数据**：Google [13] 和 OpenAI [14] 的单次提问数据由服务商自己发布，没有经过独立验证；PowerBoard 只把它们用作换算参照，不用于估算。
- **日志格式**：解析依赖各工具的本地日志格式，工具更新后可能需要适配。Antigravity 的解析尚未用真实数据核对。

## 安装

需要 macOS 14 或更高版本，Apple 芯片和 Intel 均可。

### 下载安装

1. 从 [Releases](https://github.com/Kira-Calc/PowerBoard/releases) 下载 `PowerBoard-<版本>.zip` 并解压。
2. 把 `PowerBoard.app` 移到"应用程序"文件夹。
3. 这个 App 没有 Apple 开发者签名，也没有经过公证，第一次打开时 macOS 会拦截。打开 **系统设置 > 隐私与安全性**，向下滚动，点击 **仍要打开**。也可以在终端运行：

   ```bash
   xattr -dr com.apple.quarantine /Applications/PowerBoard.app
   ```

更新版本后，macOS 可能会询问是否允许 PowerBoard 访问钥匙串中保存的 WattTime 密码，选择"始终允许"即可。

### 从源码构建

需要 Xcode 16 或更高版本，以及 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```bash
git clone https://github.com/Kira-Calc/PowerBoard.git
cd PowerBoard
xcodegen generate
open PowerBoard.xcodeproj    # 运行 PowerBoard scheme
```

打包发布用的 zip（临时签名，通用二进制）：

```bash
scripts/build-release.sh     # 输出到 dist/
```

## 终端状态栏

**Claude Code**：在 **设置 > 显示** 中打开"在 Claude Code 状态栏显示"，或运行：

```bash
/Applications/PowerBoard.app/Contents/Helpers/powerboard install-statusline
```

这会修改 `~/.claude/settings.json` 中的 `statusLine` 一项，修改前先备份。已有状态栏时，可以保留原来的并同时显示（`--combine`）。`powerboard uninstall-statusline` 会恢复原来的状态栏。

**Codex** 目前不支持自定义状态栏命令，可以在 tmux 或 iTerm2 中显示同样的内容。先把命令链接到 `PATH`：

```bash
ln -s /Applications/PowerBoard.app/Contents/Helpers/powerboard /usr/local/bin/powerboard
```

tmux（写入 `~/.tmux.conf`；`NO_COLOR=1` 用来关闭终端颜色代码）：

```tmux
set -g status-interval 30
set -g status-right '#(NO_COLOR=1 powerboard statusline --format compact --lang zh < /dev/null)'
```

iTerm2 需要通过 Python API 注册一个状态栏组件，脚本见 [README.en.md](README.en.md#terminal-status-line)。以上两个示例尚未在所有环境中测试。

## 命令行

```bash
powerboard today                    # 今日电量、碳排和 token
powerboard today --json
powerboard report --period week     # Markdown 报告；也可以用 --format json 或 csv
powerboard report --period month --date 2026-09-15 --lang zh
powerboard statusline               # 一行文字，即 Claude Code 状态栏显示的内容
```

默认输出英文。加上 `--lang zh`，或在设置中修改语言后，输出中文。

## 隐私

- 日志只在本机读取。PowerBoard 只读取 token 数、模型名、时间、会话 ID 和项目路径，不保存对话内容。活跃对话的标题取自 Claude Code 自己记录的标题，只用于列表显示，不保存。
- 数据保存在 `~/Library/Application Support/PowerBoard/`，可以在"设置 > 数据源"中删除。
- 网络请求只发往美国 EIA（不需要账号）；设置了 WattTime 和 Electricity Maps 后，也会请求这两个服务。没有统计分析或遥测。
- WattTime 密码和 Electricity Maps 密钥保存在 macOS 钥匙串中。
- PowerBoard 只会在自己的目录之外写入一个文件：`~/.claude/settings.json`，而且只在你打开状态栏功能时写入，写入前先备份。

## 参考文献

1. International Energy Agency. *Energy and AI*. 2025. https://www.iea.org/reports/energy-and-ai
2. de Vries, A. The growing energy footprint of artificial intelligence. *Joule* 7(10), 2191–2194, 2023. https://doi.org/10.1016/j.joule.2023.09.004
3. Jegham, N. et al. How Hungry is AI? Benchmarking Energy, Water, and Carbon Footprint of LLM Inference. arXiv:2505.09598, 2025 (v6). https://arxiv.org/abs/2505.09598
4. Luccioni, A. S., Jernite, Y., Strubell, E. Power Hungry Processing: Watts Driving the Cost of AI Deployment? arXiv:2311.16863, 2023 (ACM FAccT 2024). https://arxiv.org/abs/2311.16863
5. Samsi, S. et al. From Words to Watts: Benchmarking the Energy Costs of Large Language Model Inference. arXiv:2310.03003, 2023. https://arxiv.org/abs/2310.03003
6. Wittebolle, G. claude-carbon: carbon footprint tracker for Claude Code sessions. 2026. MIT License. https://github.com/gwittebolle/claude-carbon
7. Patterson, D. et al. Carbon Emissions and Large Neural Network Training. arXiv:2104.10350, 2021. https://arxiv.org/abs/2104.10350 ；Strubell, E., Ganesh, A., McCallum, A. Energy and Policy Considerations for Deep Learning in NLP. arXiv:1906.02243, 2019. https://arxiv.org/abs/1906.02243
8. WattTime. API v3 documentation (`signal-index`, `region-from-loc`). https://docs.watttime.org/
9. U.S. Energy Information Administration. Hourly Electric Grid Monitor (Form EIA-930). https://www.eia.gov/electricity/gridmonitor/
10. U.S. Environmental Protection Agency. Emissions & Generation Resource Integrated Database (eGRID2023, Rev. 2, 2025). https://www.epa.gov/egrid
11. Electricity Maps. API documentation. https://www.electricitymaps.com/
12. U.S. Environmental Protection Agency. Greenhouse Gas Equivalencies Calculator: Calculations and References. https://www.epa.gov/energy/greenhouse-gas-equivalencies-calculator-calculations-and-references
13. Elsworth, C. et al. Measuring the environmental impact of delivering AI at Google Scale. arXiv:2508.15734, 2025. https://arxiv.org/abs/2508.15734
14. Altman, S. The Gentle Singularity. June 2025. https://blog.samaltman.com/the-gentle-singularity
15. Kamiya, G. The carbon footprint of streaming video: fact-checking the headlines. IEA, 2020. https://www.iea.org/commentaries/the-carbon-footprint-of-streaming-video-fact-checking-the-headlines
16. U.S. Department of Agriculture. FoodData Central, SR Legacy (FDC ID 173944, 171287, 168878). https://fdc.nal.usda.gov/

## 引用

```
Kira-Calc. PowerBoard: estimated server-side energy and carbon of AI coding tools on macOS. 2026. https://github.com/Kira-Calc/PowerBoard
```

## 致谢与许可证

- 能耗系数来自 [claude-carbon](https://github.com/gwittebolle/claude-carbon)（MIT）。
- Codex 去重和 Antigravity 日志位置参考了 [ccusage](https://github.com/ryoppippi/ccusage)（MIT）的文档。
- 第三方声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

PowerBoard 以 [MIT 许可证](LICENSE) 发布。
