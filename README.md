# 流光（iOS 自签版）v4

**流光**——为杜比视界而生的极简播放器。名字取“光的流动”：杜比视界的逐帧光影，本质就是让光流动起来。
图标按苹果的设计语言绘制（黑白极简版）：纯黑全出血底、中央三条白色圆角横线——「流光三线」，光流过的轨迹，
无渐变、无光晕、无文字；中心符号原为播放三角，用户 2026-11-04 要求换掉，在 A 流光三线 / B 光圈 / C 日食
三候选中最终选定 A（候选生成在 tools/make_candidates.py）。图标源文件由 `tools/make_icon.py` 几何生成，可随时改形重跑。
图标只保留 A「流光三线」一款：B 光圈、C 日食与应用内图标切换功能已按用户要求于 2026-11-04 删除
（备用图标集与 Info.plist 注册一并移除），回归苹果式的一图标定版。

**v4 UI 全面改版（最低系统 iOS 26，按 Liquid Glass 设计，重点适配 iPhone SE 3 与 16 Pro Max）**：
- 信息架构改为 2 Tab：媒体库 ＋ 搜索（系统搜索 Tab），滚动时标签栏自动收起；
- 媒体库改为海报网格（2:3 占位标题图、按容器宽度自适应列数）＋「继续观看」横排卡（带进度），也可切列表；
- 工具栏收敛为「＋」导入菜单与「…」菜单（排序／网格·列表／设置），设置页含自动续播开关、
  外挂字幕字号、清除续播记录与重封装缓存；
- 续播进度改为按条目记录（含总时长），驱动继续观看与进度条；重封装进度改为玻璃卡呈现；
- 大字体（无障碍字号）时网格自动降为列表，SE 3 小屏不崩版。完整设计说明见工程内 `UI设计.md`。

一个极简的 iOS 视频播放器。v2 内置了**解析层**：
纯 Swift 实现的 Matroska（MKV）解析 + MP4 重封装，MKV 文件打开时自动无损换壳成 MP4，
再交给苹果原生 AVFoundation 播放引擎输出杜比视界——和 Infuse 同一条技术路线。

**v3 新补字幕**：
- MKV 内封**文本字幕**（S_TEXT/UTF8、ASS、SSA、WebVTT）会一并转成 MP4 的 mov_text 字幕轨带入，
  在系统播放界面里和原 MP4 一样可选轨、跟随系统字幕样式；
- **外挂字幕**：媒体库里长按条目 →「添加外挂字幕」，挂 SRT / ASS / SSA / VTT 文件，
  播放时叠加显示，并自动关掉内封字幕的默认选中避免重叠。

## 功能

- 从「文件」App 导入视频，或粘贴网络直链（MP4 / MOV / m3u8）
- **MKV 自动解析重封装**：EBML 流式解析（帧数据不进内存）→ 生成带 dvh1/dvvC 的 MP4 → 原生播放
- 杜比视界 / HDR 原生输出（iPhone 12 及以后机型）
- 系统播放界面自带：内封字幕与音轨切换、播放速度、画中画、AirPlay
- 自动记忆每部片的续播位置
- 播放界面左上角显示格式徽章（Dolby Vision / HEVC 等）
- 媒体库本地保存，左滑删除，长按条目管理外挂字幕

## 解析层支持范围（v3）

- 视频：HEVC（H.265）的 MKV；杜比视界单层（Profile 5 最常见，如 Netflix WEB-DL；
  若 MKV 里带 dvvc 配置记录则按记录走，否则扫第一帧的 RPU 自动按 Profile 5 生成配置）
- 音频：AC-3、E-AC3（含全景声）、AAC 可带入并切换；DTS、TrueHD、FLAC 等会跳过并给出提示
- 字幕（内封）：文本字幕 UTF8 / ASS / SSA / WebVTT 转 mov_text 带入；
  ASS 的特效标签、定位、字体样式会被简化为纯文本（时间轴保留）；
  **图形字幕（PGS / VobSub）仍带不了**，重封装完成时会提示跳过了哪条
- 字幕（外挂）：SRT / ASS / SSA / VTT 解析后叠加显示（纯文本，无特效样式）；
  编码兼容 UTF-8 与 GB18030（老 GBK 字幕可直接挂）；外挂与内封同时存在时以外挂为准
- 蓝光原盘的 Profile 7 双层 DV（FEL/MEL）：会检测并提示，增强层无法靠简单重封装呈现
- 重封装产物缓存在 App 的 Caches 目录，系统空间紧张时可能被自动清理，届时重新打开会再封装一次

## 签名与安装（Xcode）

1. 解压后用 Xcode 打开 `DolbyPlayer.xcodeproj`（需要 Xcode 15+，系统 iOS 17+）。
2. 选中项目 → Target「DolbyPlayer」→「Signing & Capabilities」：
   - 勾选 Automatically manage signing
   - Team 选你的 Apple ID（免费账号也可以，免费签名的 App 7 天过期，到期重装一次；付费开发者账号 1 年）
   - 把 Bundle Identifier 改成你自己的唯一值，例如 `com.dert.DolbyPlayer`
3. 数据线连接 iPhone，Xcode 顶部设备选你的手机，点 Run。
4. 首次在手机上打开前：设置 → 通用 → VPN 与设备管理 → 信任你的开发者证书。

## 在电脑上手动转封装（备选）

不想用内置解析层时，也可以在电脑上用 ffmpeg 先转好（同样无损）：

```bash
ffmpeg -i input.mkv -map 0:v:0 -map 0:a -map 0:s -c copy -c:s mov_text -tag:v dvh1 -movflags +faststart output.mp4
```

## 已知边界

- 音频：DDP（E-AC3，含全景声）系统原生支持；TrueHD 无损全景声不支持。
- 这是个人自用小工具，没有网盘直连；从夸克下载到「文件」后再导入即可。
- 解析层按 Matroska / ISOBMFF 规范手写，未经真机逐格式回归；遇到封装失败或播放异常，
  把报错信息或文件名发回给 Muse 继续修。

## 项目结构

```
DolbyPlayer.xcodeproj
DolbyPlayer/
  DolbyPlayerApp.swift   入口
  ContentView.swift      媒体库界面 + 播放流程
  LibraryStore.swift     媒体库（书签持久化、外挂字幕挂载）
  PlayerModel.swift      播放核心（加载、续播、格式识别、外挂字幕同步）
  PlayerView.swift       系统播放器包装 + 外挂字幕叠加层
  MatroskaDemuxer.swift  解析层一：EBML 解析（轨道/帧流式提取）
  MP4Remuxer.swift       解析层二：MP4 重封装（dvh1/dvvC、采样表、音频配置、mov_text 字幕轨）
  SubtitleTools.swift    字幕工具：SRT/ASS/VTT 解析、ASS 文本清洗、编码兼容
  Info.plist
  Assets.xcassets
```
