# IMEIndicator — 光标「中 / 英」角标指示器

在文本输入光标（或鼠标）右下角常驻一个小小的「中 / 英」角标，实时显示当前输入法状态，
避免中英误录、打断思路。用 AutoHotkey v2 编写，可编译成免安装的单文件 EXE。

![浅底效果](preview-lightbg.png)

## 它解决什么问题

打字时经常忘记键盘处在中文还是英文状态，等发现时已经敲进去一串错字，只能删掉重来。
这个角标把输入法状态放在你视线本来就在的地方——光标旁边——不用低头看任务栏。

## 特性

- **跟随定位**：默认跟随鼠标；当鼠标指向可输入区域（I 型光标）时，自动贴住文本插入符，
  像下标一样咬住光标右下角。取不到插入符时自动退回跟随鼠标。
- **真圆角 + 发丝边框**：用 GDI+ 逐像素透明分层窗口绘制，四条抗锯齿圆弧拼成真圆角，
  1px 描边正好压住一列像素，边缘平滑不发虚。
- **内部镂空**：只有边框和文字有像素，其余全透明，不遮挡底下的内容。
- **背景反差配色**：采样角标四周的背景亮度，自动在深浅两套配色间切换（深底用亮色、
  浅底用暗色），白底文档和深色壁纸下都看得清。色相仍区分中英（紫=中、灰=英）。
- **不打扰**：鼠标穿透、永不抢焦点、不进 Alt+Tab，不遮挡点击也不干扰输入法候选词框。
- **文字光学居中**：按实际渲染出来的墨迹质心居中，而不是按字身框——汉字字面在字身框里
  天生偏左上，只靠常规居中会一直看着歪。

![深底效果](preview-darkbg.png)

## 使用

### 方式一：直接下载 EXE（推荐，免安装）

到 [Releases](../../releases) 页面下载 `IMEIndicator.exe`，双击运行即可。
目标机器不需要安装 AutoHotkey。程序常驻托盘，右键托盘图标可以暂停指示器、立即隐藏或退出。

### 方式二：从源码运行

需要 [AutoHotkey v2.0](https://www.autohotkey.com/)：

```
AutoHotkey64.exe IMEIndicator.ahk
```

### 开机自启

按 `Win+R` 输入 `shell:startup` 打开启动文件夹，把 `IMEIndicator.exe` 的快捷方式丢进去即可。

## 配置

所有可调参数集中在脚本顶部的 `CFG` 对象里，改完重新编译（或直接重跑脚本）生效。

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `pollMs` | `80` | 轮询间隔（毫秒） |
| `followMode` | `"auto"` | `auto`=鼠标为 I 型时优先跟插入符，否则跟鼠标；`caret`=只跟插入符；`mouse`=只跟鼠标 |
| `offsetX` / `overlapY` | `3` / `6` | 跟插入符时的水平偏移 / 上移量 |
| `mouseOffX` / `mouseOffY` | `14` / `18` | 跟鼠标时相对鼠标尖端的偏移 |
| `maxCaretH` | `30` | 光标高度上限（单行控件会上报整个控件内高，需封顶） |
| `baseW` / `baseH` | `18` / `18` | 角标尺寸（96 DPI 基准） |
| `borderW` | `1.0` | 边框线宽，`1` 是发丝线，想更细可填 `0.75` |
| `cornerR` | `4` | 圆角半径 |
| `fontSize` / `fontFace` | `9` / `Microsoft YaHei` | 字号（磅）/ 字体 |
| `textDX` / `textDY` | `0` / `0` | 文字手工微调（居中已自动补偿，正常不用动） |
| `zhOnLight` / `zhOnDark` | `0x4B3FE3` / `0xA79EFF` | 「中」在浅底 / 深底的配色 |
| `enOnLight` / `enOnDark` | `0x2B3038` / `0xD8DCE4` | 「英」在浅底 / 深底的配色 |
| `lumLow` / `lumHigh` | `110` / `145` | 判定深底 / 浅底的亮度阈值，中间区间维持原判避免来回闪 |

## 自行编译

```
Ahk2Exe.exe /in IMEIndicator.ahk /out IMEIndicator.exe /base "AutoHotkey64.exe"
```

`Ahk2Exe.exe` 和 `AutoHotkey64.exe` 都在 AutoHotkey v2 的安装目录下
（`Compiler\Ahk2Exe.exe` 和 `AutoHotkey64.exe`）。

## 已知限制

- Chrome / Edge / Electron / UWP 类应用不向 Win32 上报插入符位置，在这些程序里角标会退化为
  跟随鼠标。记事本、Office、微信、QQ、钉钉等常规 Win32 程序不受影响。
- 输入法状态通过 `ImmGetConversionStatus` 的 `IME_CMODE_NATIVE` 位判断；极少数不按标准
  上报状态的第三方输入法可能读不准，此时会走 `ImmGetDefaultIMEWnd` 兜底。

## 说明

仓库里只放源码和文档，编译好的 EXE 见 Releases。