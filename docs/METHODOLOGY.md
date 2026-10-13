# PowerBoard: Methodology / 计算方法

[English](#english) | [中文](#中文)

---

## English

### What is estimated

The electricity used in AI providers' data centers to process requests sent by Claude Code, Codex and Google Antigravity on this Mac, and the carbon emitted to generate that electricity. The numbers are derived from token counts and published research. They are not measurements.

Not included: network transfer, model training, embodied emissions of hardware, and chats in claude.ai or the Claude desktop app (they write no local token logs). This Mac's own power use is shown only when you turn it on in Settings, and it is measured, not estimated (see [Local power](#local-power)).

### Token counts

| Tool | Source | How usage is counted |
| --- | --- | --- |
| Claude Code | `~/.claude/projects/**/*.jsonl` (and `CLAUDE_CONFIG_DIR`) | The `usage` field of each assistant message. Duplicates are removed by message ID plus request ID. |
| Codex | `~/.codex/sessions/**/*.jsonl` | The increase of `total_token_usage` between `token_count` events in the same file. Repeated totals are ignored. The first event in a file, and the first after a counter reset, use `last_token_usage`, so history copied into a forked session is not counted twice. Reasoning tokens are already part of output. |
| Claude Desktop | Cowork logs under `~/Library/Application Support/Claude/local-agent-mode-sessions/**/.claude/projects/`, and Code tab records in `~/.claude/projects` whose `entrypoint` is the desktop app | Same format and counting as Claude Code. Ordinary chats in the app write no token logs and are not counted. |
| Antigravity | SQLite files under `~/.gemini/antigravity*` | Usage records decoded from protobuf metadata. The same response can appear in several tables and is merged by ID. Not yet checked against real data. |

The app reads only the fields it needs for counting (token numbers, model name, time, session ID, project path). It does not store conversation content. Lines it cannot parse are skipped and counted on the Data sources page.

### Energy

```
effective input = uncached input + cache write x k_write + cache read x k_read
energy (Wh)     = effective input / 1e6 x E_in(tier) + output / 1e6 x E_out(tier)
```

Defaults: `k_write = 1.0`, `k_read = 0.08` (the published range is roughly 0.05 to 0.20). Both can be changed in Settings > Calculation.

Energy factors, version `2026.10-2`, in Wh per million tokens:

| Tier | Input | Output | Basis |
| --- | ---: | ---: | --- |
| Small | 70 | 1,439 | 0.5 x medium, extrapolated |
| Medium | 136 | 2,878 | Fitted to Jegham et al. 2025 (v6) measurements of Claude Sonnet |
| Large | 272 | 5,756 | 2 x medium, extrapolated |
| Extra large | 544 | 11,512 | 2 x large, extrapolated |

These values are the emission factors of [claude-carbon](https://github.com/gwittebolle/claude-carbon) (MIT, commit `d7313ff`) divided by the grid intensity it assumes, 0.287 kgCO2e/kWh, and rounded. They already include a data center PUE of 1.14.

Models are matched to tiers by name, first match wins:

| Name contains | Tier | Confidence |
| --- | --- | --- |
| opus | Large | Extrapolated |
| mythos, fable | Extra large | Extrapolated |
| sonnet | Medium | Measured |
| haiku | Small | Extrapolated |
| flash | Small | Assumed |
| gemini | Medium | Assumed |
| mini | Small | Assumed |
| gpt, codex | Medium | Assumed |
| anything else | Medium | Unmapped |

"Assumed" means there is no published measurement for that model family; the tier is a guess based on its likely size. OpenAI and Google models in particular have no measured factors here.

### Range

Every estimate has a low, middle and high value: low = middle x 0.5, high = middle x 2.

**This range is an assumption, not a measured uncertainty.** Published per-token energy estimates differ by more than this, depending on hardware, batch size, response length and data center. The range is there so the numbers are not read as precise.

### Carbon

```
carbon (g) = energy (Wh) / 1000 x grid intensity (gCO2e/kWh)
```

The default grid intensity is 287 gCO2e/kWh, the average that claude-carbon uses for AWS. It can be changed in Settings. Each record keeps the intensity used when it was written. "Recalculate history" applies new energy factors and cache ratios to all records.

### Grid cleanliness

Cleanliness is shown for information only. The app does not pause, delay or schedule any work.

- **Where requests run is not public.** For each provider the app uses 3 to 5 candidate data center locations taken from public reports, each with a weight. All locations are estimates and are shown with hollow dots. The list and sources are in `grid-regions.json`.
- **Live level (needs a free WattTime account).** WattTime's `signal-index` gives a percentile from 0 (cleanest) to 100 (dirtiest) that compares each grid now with its own forecast for the next 24 hours. Below 33 is shown as "cleaner", above 67 as "less clean" (adjustable). The provider level combines the candidate locations by weight. It is a relative signal: "cleaner" in a coal-heavy grid can still have more carbon per kWh than "less clean" in a hydro grid.
- **Latest published day (no account).** The fossil-free share of each candidate's balancing authority over the last 24 published hours, from the US EIA hourly grid monitor (solar, wind, hydro, nuclear and geothermal; battery output is excluded). That day is ranked against the 30 days before it in the same region: the percentile is the share of those days that were cleaner, with ties counting half, so 0 is the cleanest and 100 the least clean, the same scale and thresholds as WattTime. At least 14 earlier days are needed. The provider level combines the candidates by weight. EIA usually publishes about one day late, so this describes that day, not the grid now; it is shown with a "latest day" label, is not shown in the menu bar or the terminal status line, and is not saved with usage records. Fossil-free share is a proxy: it does not tell gas from coal.
- **Annual average (fallback).** US EPA eGRID2023 subregion emission rates. Shown as values, without a level.
- **Optional:** an Electricity Maps API key adds live carbon intensity and fossil-free share.

The grid level is saved with each new record (only for records less than 20 minutes old), so "today's energy by grid level" covers only usage after live data was connected. The carbon estimate always uses the fixed intensity above, not the grid level.

### Energy mix in reports

Reports estimate which generation sources supplied the energy. For each candidate location, the hourly generation by fuel of its balancing authority (US EIA, about the last 33 days) is summed over the report's hours; the provider mix is the weighted average of its candidates, and each tool's mid energy is split by its provider's mix. Fuels are grouped as nuclear, wind, hydro, solar, geothermal (fossil-free), natural gas, coal and other; battery output is excluded. Hours without published data, such as the latest few hours or anything older than the data kept, use the average mix of all kept hours, and the report says so. The mix is an estimate on top of estimated locations; it is not the provider's actual supply, which may include contracted renewable energy.

Reports can cover a calendar period (day, week, month, year) or a rolling one ending at the time the report is made (the last 24 hours, 7 days, 30 days or 12 months). A rolling report compares with the period of the same length right before it.

### Local power

When turned on, the app reads the whole Mac's power draw (`PowerTelemetryData.SystemLoad` from the battery controller) every 10 seconds while it runs and integrates it into Wh. Gaps longer than 60 seconds (sleep, app not running) are not filled in. Desktop Macs without this sensor cannot use the option. No carbon is estimated for local power, because the local grid is unknown.

### Everyday comparisons

Comparisons divide the middle energy estimate by a reference value. The app shows a random set of the enabled items, changing every 8 seconds, and only items whose count reads naturally (1 to 100,000). Values are in `equivalents.json`, each with its basis and source:

| Item | Wh per unit | Basis and source |
| --- | ---: | --- |
| Microwave (1000 W), 1 minute | 16.7 | Definition |
| Hair dryer (1500 W), 1 minute | 25 | Definition |
| Boiling 1 L of water | 92.9 | 4.18 kJ/(kg K) x 1 kg x 80 K, no heat loss (lower bound) |
| LED bulb (10 W), 1 hour | 10 | Definition |
| Laptop (50 W), 1 hour | 50 | Assumed typical load |
| Full smartphone charge | 19 | US EPA Greenhouse Gas Equivalencies, 0.019 kWh |
| Gemini text prompt | 0.24 | Median, Elsworth et al. 2025 (arXiv:2508.15734) |
| ChatGPT query | 0.34 | Stated by OpenAI's CEO (Altman 2025); method not published |
| Streaming video, 1 hour | 77 | IEA 2020, Netflix in 2019 |
| Average US home, 1 day | 33,408 | 12,194 kWh per year (EIA 2022, cited by US EPA) / 365 |
| Banana, 126 g | 130.3 | USDA FoodData Central 173944, 89 kcal/100 g |
| Egg, large, 50 g | 83.1 | USDA FoodData Central 171287, 143 kcal/100 g |
| Cooked white rice, 158 g | 238.7 | USDA FoodData Central 168878, 130 kcal/100 g |
| Hamburger (McDonald's US) | 290.6 | 250 kcal, McDonald's USA nutrition |
| Big Mac (McDonald's US) | 674.1 | 580 kcal, McDonald's USA nutrition |
| Cola, 355 mL can | 162.7 | 140 kcal, The Coca-Cola Company |

Food energy uses 1 kcal = 4.184 kJ = 1.1622 Wh. Food items compare electricity with food energy for scale only; they are different kinds of energy. The Google and OpenAI per-prompt figures are self-reported and not independently verified; they are used only as comparisons, not in the estimate.

### Sources

1. claude-carbon (https://github.com/gwittebolle/claude-carbon), MIT license, commit `d7313ff`: energy and emission factors, cache read ratio.
2. Jegham, N. et al. How Hungry is AI? Benchmarking Energy, Water, and Carbon Footprint of LLM Inference. arXiv:2505.09598, 2025 (v6).
3. WattTime API v3, `signal-index` and `region-from-loc`: https://docs.watttime.org/
4. US EIA Hourly Electric Grid Monitor (Form EIA-930): https://www.eia.gov/electricity/gridmonitor/
5. US EPA eGRID2023 (Rev. 2, June 2025), subregion CO2e output emission rates: https://www.epa.gov/egrid
6. Electricity Maps API (optional): https://www.electricitymaps.com/
7. US EPA, Greenhouse Gas Equivalencies Calculator: Calculations and References: https://www.epa.gov/energy/greenhouse-gas-equivalencies-calculator-calculations-and-references
8. Elsworth, C. et al. Measuring the environmental impact of delivering AI at Google Scale. arXiv:2508.15734, 2025.
9. Altman, S. The Gentle Singularity. June 2025. https://blog.samaltman.com/the-gentle-singularity
10. Kamiya, G. The carbon footprint of streaming video: fact-checking the headlines. IEA, 2020.
11. USDA FoodData Central, SR Legacy: https://fdc.nal.usda.gov/
12. McDonald's USA nutrition (Hamburger, Big Mac) and The Coca-Cola Company (Coca-Cola Original), product pages.

---

## 中文

### 估算的是什么

AI 服务商的数据中心处理本机 Claude Code、Codex 和 Google Antigravity 发出的请求时消耗的电量，以及发电产生的碳排。数值根据 token 数量和公开研究推算，不是实测值。

不包括：网络传输、模型训练、硬件制造的隐含排放，以及 claude.ai 网页版和 Claude 桌面应用中的聊天（它们不在本地写 token 日志）。本机耗电只在设置中打开后显示，而且是实测值，不是估算（见[本机耗电](#本机耗电)）。

### token 统计

| 工具 | 来源 | 计数方式 |
| --- | --- | --- |
| Claude Code | `~/.claude/projects/**/*.jsonl`（以及 `CLAUDE_CONFIG_DIR`） | 每条助手消息的 `usage` 字段，按消息 ID 加请求 ID 去重。 |
| Codex | `~/.codex/sessions/**/*.jsonl` | 同一文件中相邻 `token_count` 事件之间 `total_token_usage` 的增量，累计值重复的事件忽略。文件中的第一个事件，以及计数器重置后的第一个事件，改用 `last_token_usage`，避免分叉会话复制过来的历史被重复计算。推理 token 已包含在输出中。 |
| Claude Desktop | Cowork 日志位于 `~/Library/Application Support/Claude/local-agent-mode-sessions/**/.claude/projects/`；Code 标签页的记录写在 `~/.claude/projects`，`entrypoint` 为桌面版 | 格式和计数方式与 Claude Code 相同。桌面版中的普通聊天不在本机写入 token 日志，不统计。 |
| Antigravity | `~/.gemini/antigravity*` 下的 SQLite 文件 | 从 protobuf 元数据中解码用量记录。同一个响应可能出现在多张表里，按 ID 合并。尚未用真实数据核对。 |

App 只读取计数需要的字段（token 数、模型名、时间、会话 ID、项目路径），不保存对话内容。无法解析的行会跳过，并在"数据源"页显示数量。

### 电量

```
有效输入 = 未缓存输入 + 缓存写入 x k_write + 缓存读取 x k_read
电量 (Wh) = 有效输入 / 1e6 x E_in(档位) + 输出 / 1e6 x E_out(档位)
```

默认 `k_write = 1.0`，`k_read = 0.08`（公开资料的范围约为 0.05 到 0.20）。两个值都可以在"设置 > 计算方法"中修改。

能耗系数，版本 `2026.10-2`，单位 Wh/百万 token：

| 档位 | 输入 | 输出 | 依据 |
| --- | ---: | ---: | --- |
| 小 | 70 | 1,439 | 中档的 0.5 倍，外推 |
| 中 | 136 | 2,878 | 拟合 Jegham et al. 2025（v6）对 Claude Sonnet 的测量 |
| 大 | 272 | 5,756 | 中档的 2 倍，外推 |
| 特大 | 544 | 11,512 | 大档的 2 倍，外推 |

这些数值由 claude-carbon（MIT，commit `d7313ff`）的碳排系数除以它采用的电网碳强度 0.287 kgCO2e/kWh 得到，并取整。系数已经包含数据中心 PUE 1.14。

模型按名称匹配档位，从上到下取第一个命中的规则：

| 名称包含 | 档位 | 可信度 |
| --- | --- | --- |
| opus | 大 | 外推 |
| mythos、fable | 特大 | 外推 |
| sonnet | 中 | 实测 |
| haiku | 小 | 外推 |
| flash | 小 | 假设 |
| gemini | 中 | 假设 |
| mini | 小 | 假设 |
| gpt、codex | 中 | 假设 |
| 其他 | 中 | 未匹配 |

"假设"表示该系列模型没有公开的测量数据，档位是按可能的模型规模推测的。特别是 OpenAI 和 Google 的模型，这里没有实测系数。

### 区间

每个估算值都有低、中、高三个值：低值 = 中值 x 0.5，高值 = 中值 x 2。

**这个区间是假设值，不是实测的不确定度。** 公开的每 token 能耗估算因硬件、批大小、回复长度和数据中心不同，差距比这更大。设置区间是为了避免把数值当成精确结果。

### 碳排

```
碳排 (g) = 电量 (Wh) / 1000 x 电网碳强度 (gCO2e/kWh)
```

默认电网碳强度为 287 gCO2e/kWh，即 claude-carbon 采用的 AWS 平均值，可以在设置中修改。每条记录保存写入时使用的碳强度。"重新计算历史"会把新的能耗系数和缓存比例应用到所有记录。

### 电网洁净度

洁净度只提供信息。App 不会暂停、推迟或安排你的任何任务。

- **请求在哪里处理并不公开。** 每家服务商使用 3 到 5 个根据公开报道推测的候选数据中心地点，各带一个权重。所有地点都是推测的，显示为空心圆点。地点列表和资料来源见 `grid-regions.json`。
- **实时等级（需要免费的 WattTime 账号）。** WattTime 的 `signal-index` 给出 0（最清洁）到 100（最不清洁）的百分位，比较的是各电网此刻与它自己未来 24 小时的预测。低于 33 显示为"较清洁"，高于 67 显示为"较不清洁"（可调）。服务商的等级是各候选地点按权重合并的结果。这是相对指标：以煤电为主的电网"较清洁"时，每度电的碳排仍可能高于以水电为主的电网"较不清洁"时。
- **最近发布的一天（不需要账号）。** 来自美国 EIA 小时电网监测，是各候选地点所属平衡区最近 24 个已发布小时的清洁电力占比（太阳能、风电、水电、核电和地热，不计储能电池）。这一天会与同一地区之前 30 天比较：百分位等于其中更清洁的天数所占比例，持平的天数按一半计，所以 0 最清洁、100 最不清洁，刻度和阈值与 WattTime 相同。至少需要 14 天的历史数据。服务商的等级是各候选地点按权重合并的结果。EIA 通常晚一天左右发布，所以它描述的是那一天，不代表此刻；界面上标注为"最近一天"，不显示在菜单栏和终端状态栏中，也不记录到用量中。清洁电力占比只是近似指标，它不区分燃气和燃煤。
- **年均值（回退）。** 美国 EPA eGRID2023 各子区域的排放率。只显示数值，不显示等级。
- **可选：** 填入 Electricity Maps API 密钥后，补充实时碳强度和清洁电力占比。

电网等级随每条新记录保存（只保存给 20 分钟以内的新记录），所以"今日用电按电网等级"只包含连接实时数据之后的用电。碳排估算始终使用上面的固定碳强度，不使用电网等级。

### 报告中的能源结构

报告会估算这些电量来自哪些发电来源。每个候选地点取其所属平衡区的逐小时分燃料发电量（美国 EIA，保留约最近 33 天），在报告时段内求和；服务商的结构是各候选地点按权重的加权平均，再把每个工具的电量中值按对应服务商的结构拆分。燃料分为核电、风电、水电、太阳能、地热（清洁电力）以及燃气、燃煤和其他，不计储能电池。没有已发布数据的时段（例如最近几个小时，或早于保留范围的时段）使用全部保留时段的平均结构，报告中会注明。这个结构建立在推测的地点之上，只是估算；它不是服务商实际的供电构成，服务商可能另有签约的可再生能源。

报告可以按日历计算（自然日、周、月、年），也可以按截至生成时刻的滚动区间计算（过去 24 小时、7 天、30 天、12 个月）。滚动报告与紧挨在它之前、长度相同的区间比较。

### 本机耗电

打开后，App 运行期间每 10 秒读取一次整台 Mac 的功率（电池控制器的 `PowerTelemetryData.SystemLoad`），并积分为 Wh。超过 60 秒的间隔（睡眠、App 未运行）不补算。没有这个传感器的台式 Mac 无法使用此项。本机部分不估算碳排，因为本地电网未知。

### 日常换算

换算用电量中值除以参考值。App 从你启用的项目中随机选取一组显示，每 8 秒更换一次，并且只选取次数读起来自然（1 到 100,000）的项目。数值保存在 `equivalents.json` 中，每一项都写明依据和来源：

| 项目 | 每单位 Wh | 依据与来源 |
| --- | ---: | --- |
| 微波炉（1000 W）1 分钟 | 16.7 | 按定义计算 |
| 吹风机（1500 W）1 分钟 | 25 | 按定义计算 |
| 烧开 1 L 水 | 92.9 | 4.18 kJ/(kg K) x 1 kg x 80 K，不计热损失（下限） |
| LED 灯泡（10 W）1 小时 | 10 | 按定义计算 |
| 笔记本电脑（50 W）1 小时 | 50 | 假设的常见负载 |
| 给手机充满一次电 | 19 | 美国 EPA 温室气体当量计算器，0.019 kWh |
| Gemini 文本提问 1 次 | 0.24 | 中位数，Elsworth et al. 2025（arXiv:2508.15734） |
| ChatGPT 提问 1 次 | 0.34 | OpenAI CEO 自述（Altman 2025），未公开方法 |
| 在线看视频 1 小时 | 77 | IEA 2020，2019 年的 Netflix |
| 美国家庭平均 1 天 | 33,408 | 每年 12,194 kWh（EIA 2022，经美国 EPA 引用）/ 365 |
| 香蕉 126 g | 130.3 | USDA FoodData Central 173944，89 kcal/100 g |
| 大号鸡蛋 50 g | 83.1 | USDA FoodData Central 171287，143 kcal/100 g |
| 米饭 158 g | 238.7 | USDA FoodData Central 168878，130 kcal/100 g |
| 汉堡（麦当劳美国） | 290.6 | 250 kcal，麦当劳美国营养数据 |
| 巨无霸（麦当劳美国） | 674.1 | 580 kcal，麦当劳美国营养数据 |
| 罐装可乐 355 mL | 162.7 | 140 kcal，可口可乐公司 |

食物热量按 1 kcal = 4.184 kJ = 1.1622 Wh 换算。食物项只是把电能和食物热量放在一起比较大小，两者不是同一种能量。Google 和 OpenAI 的单次提问数据由服务商自己发布，没有经过独立验证，只用于换算参照，不参与估算。

### 资料来源

与英文部分的"Sources"相同，编号一致：

1. claude-carbon（https://github.com/gwittebolle/claude-carbon），MIT 许可证，commit `d7313ff`：能耗与碳排系数、缓存读取比例。
2. Jegham, N. et al. How Hungry is AI? arXiv:2505.09598, 2025 (v6)。
3. WattTime API v3：https://docs.watttime.org/
4. 美国 EIA 小时电网监测（EIA-930）：https://www.eia.gov/electricity/gridmonitor/
5. 美国 EPA eGRID2023（Rev. 2，2025 年 6 月）：https://www.epa.gov/egrid
6. Electricity Maps API（可选）：https://www.electricitymaps.com/
7. 美国 EPA 温室气体当量计算器的计算方法与参考资料。
8. Elsworth, C. et al. arXiv:2508.15734, 2025。
9. Altman, S. The Gentle Singularity, 2025 年 6 月。
10. Kamiya, G. IEA, 2020。
11. USDA FoodData Central，SR Legacy。
12. 麦当劳美国营养数据、可口可乐公司产品页。
