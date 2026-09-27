#Requires AutoHotkey v2.0
#SingleInstance Force

; ---------------------------- 编译信息 ------------------------------------
; Ahk2Exe 编译时写进 EXE 的版本资源（右键属性 → 详细信息里可见）
;@Ahk2Exe-SetVersion 1.1.0
;@Ahk2Exe-SetName IMEIndicator
;@Ahk2Exe-SetDescription 光标「中 / 英」角标指示器

; ==========================================================================
;  光标「中 / 英」角标指示器   IME Caret Indicator
;  作用：常驻显示当前输入法状态，避免中英误录、打断思路
;  样式：GDI+ 抗锯齿描边 —— 真圆角、发丝细边框、内部全透明镂空；
;        文字按实际墨迹质心居中（汉字字面天生偏左上，只靠 GDI+ 居中会歪）；
;        配色随角标周围背景的明暗自动反差（深底用亮色，浅底用暗色）
;  定位：默认跟随鼠标；鼠标指向可输入区域（I 型光标）时，自动贴住文本插入符
;  运行：需 AutoHotkey v2.0；用 Ahk2Exe 编译成 exe 后，目标机器无需装 AHK
;  状态：主路径读窗口的 IME 上下文；提权程序（任务管理器）和 TSF 程序拿不到上下文，
;        自动退回读任务栏右下角的输入指示器（由 explorer 托管，普通权限即可读）
;  范围：覆盖常用桌面应用（记事本 / Office / 微信 / QQ / 钉钉等 Win32 程序）
;  说明：Chrome / Electron / UWP 类应用不向 Win32 上报插入符，此时退化为跟随鼠标
; ==========================================================================

; ---------------------------- 可调参数 ------------------------------------
CFG := {
    pollMs     : 80,          ; 轮询间隔（毫秒）
    followMode : "auto",      ; auto=鼠标为 I 型时优先跟插入符，否则跟鼠标；caret=只跟插入符；mouse=只跟鼠标
    offsetX    : 3,           ; 跟插入符时：相对插入符右下角的水平偏移
    overlapY   : 6,           ; 跟插入符时：上移量，让它像下标一样咬住光标底部
    mouseOffX  : 14,          ; 跟鼠标时：相对鼠标尖端的水平偏移
    mouseOffY  : 18,          ; 跟鼠标时：相对鼠标尖端的垂直偏移
    maxCaretH  : 30,          ; 光标高度上限（单行控件会上报整个控件内高，需封顶）

    baseW      : 18,          ; 角标宽度（96 DPI 基准）
    baseH      : 18,          ; 角标高度（96 DPI 基准）
    borderW    : 1.0,         ; 边框线宽（96 DPI 基准）；1 = 一根发丝线，想更细可填 0.75
    cornerR    : 4,           ; 真圆角半径（96 DPI 基准），由 GDI+ 抗锯齿圆弧画出
    fontSize   : 9,           ; 字号（磅）
    fontFace   : "Microsoft YaHei",
    textDX     : 0,           ; 文字水平微调（像素，正数右移）；居中已自动补偿，这里只做手工微调
    textDY     : 0,           ; 文字垂直微调（像素，正数下移）
    alpha      : 255,         ; 整体不透明度 0-255

    ; —— 反差配色：按角标周围背景的明暗自动二选一，色相仍区分中 / 英 ——
    zhOnLight  : 0x4B3FE3,    ; 浅底 → 中：深蓝紫
    zhOnDark   : 0xA79EFF,    ; 深底 → 中：亮蓝紫
    enOnLight  : 0x2B3038,    ; 浅底 → 英：近黑灰
    enOnDark   : 0xD8DCE4,    ; 深底 → 英：近白灰
    lumLow     : 110,         ; 平均亮度低于此值 → 判为深底
    lumHigh    : 145,         ; 平均亮度高于此值 → 判为浅底；区间内维持原判，避免来回闪
    sampleGap  : 3,           ; 取样点距角标外框的距离（像素）

    trayFallback : true,      ; IME 上下文读不到时，退回读任务栏输入指示器（任务管理器等提权程序）
    trayRetryMs  : 2000       ; 指示器没找到时的重找间隔（毫秒）
}

; ---------------------------- 初始化 --------------------------------------
; AHK v2 中 Mouse/Pixel 的 CoordMode 默认是 Client，必须显式改成 Screen
CoordMode("Caret", "Screen")
CoordMode("Mouse", "Screen")
CoordMode("Pixel", "Screen")

dpiScale := 1
try dpiScale := A_ScreenDPI / 96

tagW := Round(CFG.baseW * dpiScale)
tagH := Round(CFG.baseH * dpiScale)
penW := CFG.borderW * dpiScale
if (penW < 0.6)
    penW := 0.6

; 画布比角标本体四周各大 pad 像素：给描边留余量。
; 不留余量的话，贴到位图右/下边的描边会被位图边界裁掉。
pad  := Max(2, Round(2 * dpiScale))
bmpW := tagW + pad * 2
bmpH := tagH + pad * 2

; GDI+ 在「从位图取 Graphics」时，坐标原点落在像素格左上角之外半像素，
; 也就是说 GDI+ 坐标 c 对应像素格里的 c+0.5。所以角标外框 [pad, pad+tagW]
; 这一圈像素，在 GDI+ 坐标里是 [pad-0.5, pad+tagW-0.5]。
; 描边中心线和文字矩形都按这个基准算，1px 的线才正好压住一列像素。
; （按 pad 算的话，线会横跨两列像素、各半透明 —— 就是描边发虚、外框看着偏大的原因）
originFix := 0.5

GdiplusStartup()

; AHK v2 读取未赋值变量会直接抛错，GDI 句柄必须先显式置 0
gdiToken    := 0
g_hdcScreen := 0
g_hdcMem    := 0
g_hbm       := 0
g_hbmBlank  := 0

; 逐像素透明分层窗口：只有 UpdateLayeredWindow 才能画出抗锯齿的真圆角细描边。
; （旧的 WinSetTransColor 是 1 位透明键色，圆弧边缘只能被硬切成锯齿，就是"切角"的来源）
; +E0x20       = WS_EX_TRANSPARENT  鼠标穿透，不挡点击
; +E0x08000000 = WS_EX_NOACTIVATE   永不抢焦点
; +ToolWindow  不进 Alt+Tab；+AlwaysOnTop 始终置顶
tagGui := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x20 +E0x08000000 -DPIScale", "IMEIndicator")
tagGui.MarginX := 0
tagGui.MarginY := 0
tagGui.BackColor := "000000"
tagGui.Show("NA x-32000 y-32000 w" bmpW " h" bmpH)
WinSetExStyle("+0x80000", tagGui)          ; WS_EX_LAYERED

; 注意：这个窗口只要 Hide() 过一次，之后再调 UpdateLayeredWindow 就恒返回
; ERROR_INVALID_PARAMETER(87)，WinShow 也救不回来（实测确认）。
; 所以「隐藏」不用 Hide()，而是推一张全透明位图：窗口还在，但一个像素都不画。
EnsureDC()
g_hbmBlank := CreateBlankBitmap()
UseBitmap(g_hbmBlank)
Present(-32000, -32000)

lastText  := ""
lastCol   := -1
lastX     := -99999
lastY     := -99999
isVisible := false
paused    := false
bgDark    := false                          ; 当前判定的背景明暗
smpX      := -99999
smpY      := -99999

gUia       := 0                             ; IUIAutomation（惰性创建，只在需要兜底时才建）
gIndEl     := 0                             ; 任务栏输入指示器元素（缓存；失效就丢掉重找）
gIndNextTry := 0                            ; 下次允许重找指示器的时间戳

; ---------------------------- 托盘菜单 ------------------------------------
A_IconTip := "光标中英角标指示器"
A_TrayMenu.Delete()
A_TrayMenu.Add("暂停指示器", TogglePause)
A_TrayMenu.Add("立即隐藏", HideTag)
A_TrayMenu.Add()
A_TrayMenu.Add("退出", (*) => ExitApp())
A_TrayMenu.Default := "暂停指示器"

; ---------------------------- 主循环 --------------------------------------
SetTimer(Watch, CFG.pollMs)
Persistent()

TrayTip("光标中英角标已启动", "输入时留意光标右下角的「中 / 英」提示；右键托盘图标可暂停或退出。")

Watch() {
    global tagGui, CFG, tagW, tagH, dpiScale
    global lastText, lastCol, lastX, lastY, isVisible, paused, bgDark, smpX, smpY

    if paused
        return

    hwndFG := DllCall("GetForegroundWindow", "Ptr")
    if (!hwndFG || hwndFG = tagGui.Hwnd) {
        HideTag()
        return
    }

    ; 一次调用同时拿到焦点控件和插入符高度（判定输入法状态、定位都要用）
    caretH := 0
    hwndFocus := GetFocusAndCaretHeight(hwndFG, &caretH)
    if !caretH
        caretH := Round(18 * dpiScale)
    if (caretH > Round(CFG.maxCaretH * dpiScale))
        caretH := Round(CFG.maxCaretH * dpiScale)

    ; 判定输入法状态：1=中，0=英，-1=无法判定
    mode := GetIMEMode(hwndFocus)
    if (mode < 0)
        mode := TrayIme_Mode()          ; 提权 / TSF 程序读不到 IME 上下文，退回读任务栏输入指示器
    if (mode < 0) {
        HideTag()
        return
    }

    ; 定位：鼠标指向可输入区域（I 型光标）时，优先贴住文本插入符；否则跟随鼠标
    isBeam := false
    try isBeam := (A_Cursor = "IBeam")
    wantCaret := (CFG.followMode = "caret") || (CFG.followMode = "auto" && isBeam)

    caretOK := false
    cx := 0
    cy := 0
    if wantCaret {
        if CaretGetPos(&cx, &cy) && cx > -30000 && cy > -30000
            caretOK := true
    }

    if caretOK {
        x := cx + Round(CFG.offsetX * dpiScale)
        y := cy + caretH - Round(CFG.overlapY * dpiScale)
    } else {
        MouseGetPos(&mx, &my)
        x := mx + Round(CFG.mouseOffX * dpiScale)
        y := my + Round(CFG.mouseOffY * dpiScale)
    }

    ; 背景明暗：位置基本没动就不重新取样，免得读到角标自己画出来的像素
    if (Abs(x - smpX) >= 2 || Abs(y - smpY) >= 2) {
        smpX := x
        smpY := y
        lum := SampleLum(x, y)
        if (lum < CFG.lumLow)
            bgDark := true
        else if (lum > CFG.lumHigh)
            bgDark := false
    }

    txt := (mode = 1) ? "中" : "英"
    col := (mode = 1) ? (bgDark ? CFG.zhOnDark : CFG.zhOnLight) : (bgDark ? CFG.enOnDark : CFG.enOnLight)

    needDraw := (txt != lastText) || (col != lastCol)
    if needDraw {
        RenderBadge(txt, col)
        lastText := txt
        lastCol := col
    }

    if (!isVisible) {
        UseBitmap(g_hbm)                 ; 从全透明位图切回角标
        Present(x, y)
        isVisible := true
    } else if (needDraw || x != lastX || y != lastY) {
        Present(x, y)
    }

    lastX := x
    lastY := y
}

HideTag(*) {
    global isVisible, g_hbmBlank, lastX, lastY
    if isVisible {
        UseBitmap(g_hbmBlank)            ; 推全透明位图代替 Hide()，见上方说明
        Present(lastX, lastY)
        isVisible := false
    }
}

TogglePause(*) {
    global paused
    paused := !paused
    if paused {
        HideTag()
        A_TrayMenu.Check("暂停指示器")
    } else {
        A_TrayMenu.Uncheck("暂停指示器")
    }
}

; ---------------------------- 背景取样 ------------------------------------
; 取角标外框四周 4 个点的平均亮度（0-255）。取样点都在角标之外，
; 所以读到的是真正的背景，不会读到角标自己。
SampleLum(x, y) {
    global tagW, tagH, CFG
    g := CFG.sampleGap
    pts := [[x - g, y + tagH // 2], [x + tagW + g, y + tagH // 2]
          , [x + tagW // 2, y - g], [x + tagW // 2, y + tagH + g]]

    sum := 0
    n := 0
    for p in pts {
        px := p[1]
        py := p[2]
        if (px < 0 || py < 0 || px >= A_ScreenWidth || py >= A_ScreenHeight)
            continue
        c := PixelGetColor(px, py, "RGB")
        sum += 0.299 * ((c >> 16) & 0xFF) + 0.587 * ((c >> 8) & 0xFF) + 0.114 * (c & 0xFF)
        n += 1
    }
    return n ? sum / n : 255
}

; ---------------------------- GDI+ 绘制 -----------------------------------
GdiplusStartup() {
    global gdiToken
    si := Buffer(24, 0)
    NumPut("UInt", 1, si, 0)                 ; GdiplusVersion
    gdiToken := 0
    DllCall("gdiplus\GdiplusStartup", "Ptr*", &gdiToken, "Ptr", si, "Ptr", 0)
}

; 把圆角描边 + 文字画进 32bpp 位图，再转成 HBITMAP 挂到内存 DC 上
RenderBadge(txt, rgb) {
    global bmpW, bmpH, tagW, tagH, pad, penW, dpiScale, originFix, CFG, g_hbm, g_hdcMem
    EnsureDC()

    argb := 0xFF000000 | rgb

    pBitmap := 0
    DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", bmpW, "Int", bmpH, "Int", 0
          , "Int", 0x26200A, "Ptr", 0, "Ptr*", &pBitmap)            ; PixelFormat32bppARGB
    pGraphics := 0
    DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", pBitmap, "Ptr*", &pGraphics)
    DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", pGraphics, "Int", 4)      ; AntiAlias
    DllCall("gdiplus\GdipSetTextRenderingHint", "Ptr", pGraphics, "Int", 4)  ; AntiAlias
    DllCall("gdiplus\GdipSetPixelOffsetMode", "Ptr", pGraphics, "Int", 3)    ; None：坐标直接落在像素格上，1px 线才不发虚

    ; 真圆角路径：四条抗锯齿圆弧首尾相接，连线由 GDI+ 自动补。
    ; 中心线按像素格基准算（见 originFix 说明），1px 描边正好铺满一列像素。
    x0 := pad - originFix + penW / 2
    y0 := pad - originFix + penW / 2
    x1 := pad + tagW - originFix - penW / 2
    y1 := pad + tagH - originFix - penW / 2
    r := CFG.cornerR * dpiScale
    maxR := ((x1 - x0) < (y1 - y0) ? (x1 - x0) : (y1 - y0)) / 2
    if (r > maxR)
        r := maxR

    pPath := 0
    DllCall("gdiplus\GdipCreatePath", "Int", 0, "Ptr*", &pPath)
    GdipAddArc(pPath, x1 - 2 * r, y0, 2 * r, 2 * r, 270, 90)        ; 右上
    GdipAddArc(pPath, x1 - 2 * r, y1 - 2 * r, 2 * r, 2 * r, 0, 90)  ; 右下
    GdipAddArc(pPath, x0, y1 - 2 * r, 2 * r, 2 * r, 90, 90)         ; 左下
    GdipAddArc(pPath, x0, y0, 2 * r, 2 * r, 180, 90)                ; 左上
    DllCall("gdiplus\GdipClosePathFigure", "Ptr", pPath)

    pPen := 0
    DllCall("gdiplus\GdipCreatePen1", "UInt", argb, "Float", penW, "Int", 2, "Ptr*", &pPen)
    DllCall("gdiplus\GdipDrawPath", "Ptr", pGraphics, "Ptr", pPen, "Ptr", pPath)

    ; 文字：居中，不开自动换行。
    ; 矩形基准同样按像素格算；再把 TextCenterFix 量出来的补偿加上，
    ; 让「墨迹」的中心（而不是字面框的中心）落在角标正中 —— 汉字字面在字身框里
    ; 天生偏左上，只靠 GDI+ 居中会一直偏。
    fix := TextCenterFix(txt)
    pFamily := 0
    DllCall("gdiplus\GdipCreateFontFamilyFromName", "Str", CFG.fontFace, "Ptr", 0, "Ptr*", &pFamily)
    pFont := 0
    DllCall("gdiplus\GdipCreateFont", "Ptr", pFamily, "Float", CFG.fontSize, "Int", 1, "Int", 3, "Ptr*", &pFont)
    pFmt := 0
    DllCall("gdiplus\GdipCreateStringFormat", "Int", 0, "Int", 0, "Ptr*", &pFmt)
    DllCall("gdiplus\GdipSetStringFormatAlign", "Ptr", pFmt, "Int", 1)       ; Center
    DllCall("gdiplus\GdipSetStringFormatLineAlign", "Ptr", pFmt, "Int", 1)   ; Center
    DllCall("gdiplus\GdipSetStringFormatFlags", "Ptr", pFmt, "Int", 0x1000)  ; NoWrap
    pBrush := 0
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", argb, "Ptr*", &pBrush)

    rf := Buffer(16, 0)
    NumPut("Float", pad - originFix + CFG.textDX * dpiScale + fix.dx, rf, 0)
    NumPut("Float", pad - originFix + CFG.textDY * dpiScale + fix.dy, rf, 4)
    NumPut("Float", tagW, rf, 8)
    NumPut("Float", tagH, rf, 12)
    DllCall("gdiplus\GdipDrawString", "Ptr", pGraphics, "Str", txt, "Int", -1, "Ptr", pFont
          , "Ptr", rf, "Ptr", pFmt, "Ptr", pBrush)

    ; 转 HBITMAP：GDI+ 会顺带把 alpha 预乘好，正好喂给 UpdateLayeredWindow
    hbmNew := 0
    DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "Ptr", pBitmap, "Ptr*", &hbmNew, "UInt", 0)

    UseBitmap(hbmNew)
    if g_hbm
        DllCall("DeleteObject", "Ptr", g_hbm)     ; 上一帧的角标位图已不被选中，可以删
    g_hbm := hbmNew

    DllCall("gdiplus\GdipDeleteBrush", "Ptr", pBrush)
    DllCall("gdiplus\GdipDeleteStringFormat", "Ptr", pFmt)
    DllCall("gdiplus\GdipDeleteFont", "Ptr", pFont)
    DllCall("gdiplus\GdipDeleteFontFamily", "Ptr", pFamily)
    DllCall("gdiplus\GdipDeletePen", "Ptr", pPen)
    DllCall("gdiplus\GdipDeletePath", "Ptr", pPath)
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", pGraphics)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
}

; 用浮点版 Arc：坐标不做取整，圆角才能和四条边严丝合缝（取整会差半个像素、出现缺口）
GdipAddArc(pPath, x, y, w, h, sa, sw) {
    DllCall("gdiplus\GdipAddPathArc", "Ptr", pPath, "Float", x, "Float", y
          , "Float", w, "Float", h, "Float", sa, "Float", sw)
}

; 量出文字「墨迹质心」相对角标中心的偏差，返回要给文字矩形加的补偿量。
; 为什么要量：GDI+ 的居中是把「字身框」摆正，而汉字字面在字身框里天生偏左上，
; 于是外框看着就像偏右偏下。按实际渲染出来的像素求质心再补回来，才是真居中。
; 同一组「字 + 字体 + 字号 + 角标尺寸」只量一次，之后走缓存。
TextCenterFix(txt) {
    global CFG, tagW, tagH, pad, dpiScale, originFix
    static cache := Map()

    key := txt "|" CFG.fontFace "|" CFG.fontSize "|" tagW "x" tagH "|" dpiScale
    if cache.Has(key)
        return cache[key]

    cw := tagW + pad * 2
    ch := tagH + pad * 2

    ; 临时位图上只画文字（不画边框，免得边框像素混进质心）
    pBitmap := 0
    DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", cw, "Int", ch, "Int", 0
          , "Int", 0x26200A, "Ptr", 0, "Ptr*", &pBitmap)
    pGraphics := 0
    DllCall("gdiplus\GdipGetImageGraphicsContext", "Ptr", pBitmap, "Ptr*", &pGraphics)
    DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", pGraphics, "Int", 4)
    DllCall("gdiplus\GdipSetTextRenderingHint", "Ptr", pGraphics, "Int", 4)
    DllCall("gdiplus\GdipSetPixelOffsetMode", "Ptr", pGraphics, "Int", 3)

    pFamily := 0
    DllCall("gdiplus\GdipCreateFontFamilyFromName", "Str", CFG.fontFace, "Ptr", 0, "Ptr*", &pFamily)
    pFont := 0
    DllCall("gdiplus\GdipCreateFont", "Ptr", pFamily, "Float", CFG.fontSize, "Int", 1, "Int", 3, "Ptr*", &pFont)
    pFmt := 0
    DllCall("gdiplus\GdipCreateStringFormat", "Int", 0, "Int", 0, "Ptr*", &pFmt)
    DllCall("gdiplus\GdipSetStringFormatAlign", "Ptr", pFmt, "Int", 1)
    DllCall("gdiplus\GdipSetStringFormatLineAlign", "Ptr", pFmt, "Int", 1)
    DllCall("gdiplus\GdipSetStringFormatFlags", "Ptr", pFmt, "Int", 0x1000)
    pBrush := 0
    DllCall("gdiplus\GdipCreateSolidFill", "UInt", 0xFFFFFFFF, "Ptr*", &pBrush)

    rf := Buffer(16, 0)
    NumPut("Float", pad - originFix, rf, 0)
    NumPut("Float", pad - originFix, rf, 4)
    NumPut("Float", tagW, rf, 8)
    NumPut("Float", tagH, rf, 12)
    DllCall("gdiplus\GdipDrawString", "Ptr", pGraphics, "Str", txt, "Int", -1, "Ptr", pFont
          , "Ptr", rf, "Ptr", pFmt, "Ptr", pBrush)

    ; 质心：以 alpha 为权重、以像素中心为坐标。连续量，不会因为取整跳来跳去。
    sumA := 0, sumX := 0, sumY := 0
    Loop (ch) {
        yy := A_Index - 1
        Loop (cw) {
            xx := A_Index - 1
            c := 0
            DllCall("gdiplus\GdipBitmapGetPixel", "Ptr", pBitmap, "Int", xx, "Int", yy, "UInt*", &c)
            a := (c >> 24) & 0xFF
            if (a > 0) {
                sumA += a
                sumX += a * (xx + 0.5)
                sumY += a * (yy + 0.5)
            }
        }
    }

    DllCall("gdiplus\GdipDeleteBrush", "Ptr", pBrush)
    DllCall("gdiplus\GdipDeleteStringFormat", "Ptr", pFmt)
    DllCall("gdiplus\GdipDeleteFont", "Ptr", pFont)
    DllCall("gdiplus\GdipDeleteFontFamily", "Ptr", pFamily)
    DllCall("gdiplus\GdipDeleteGraphics", "Ptr", pGraphics)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)

    fix := {dx: 0, dy: 0}
    if (sumA > 0) {
        fix.dx := (pad + tagW / 2) - sumX / sumA
        fix.dy := (pad + tagH / 2) - sumY / sumA
    }
    cache[key] := fix
    return fix
}

; 全透明位图：用来「隐藏」角标 —— 窗口保持可见，只是一个像素都不画
CreateBlankBitmap() {
    global bmpW, bmpH
    pBitmap := 0
    DllCall("gdiplus\GdipCreateBitmapFromScan0", "Int", bmpW, "Int", bmpH, "Int", 0
          , "Int", 0x26200A, "Ptr", 0, "Ptr*", &pBitmap)
    hbm := 0
    DllCall("gdiplus\GdipCreateHBITMAPFromBitmap", "Ptr", pBitmap, "Ptr*", &hbm, "UInt", 0)
    DllCall("gdiplus\GdipDisposeImage", "Ptr", pBitmap)
    return hbm
}

UseBitmap(hbm) {
    global g_hdcMem
    DllCall("SelectObject", "Ptr", g_hdcMem, "Ptr", hbm, "Ptr")
}

EnsureDC() {
    global g_hdcMem, g_hdcScreen
    if !g_hdcScreen
        g_hdcScreen := DllCall("GetDC", "Ptr", 0, "Ptr")
    if !g_hdcMem
        g_hdcMem := DllCall("CreateCompatibleDC", "Ptr", g_hdcScreen, "Ptr")
}

; 把内存 DC 里的位图贴到分层窗口的 (x, y)
Present(x, y) {
    global tagGui, bmpW, bmpH, pad, CFG, g_hdcMem, g_hdcScreen
    ptDst := Buffer(8, 0)
    NumPut("Int", x - pad, ptDst, 0)
    NumPut("Int", y - pad, ptDst, 4)
    sz := Buffer(8, 0)
    NumPut("Int", bmpW, sz, 0)
    NumPut("Int", bmpH, sz, 4)
    ptSrc := Buffer(8, 0)
    blend := Buffer(4, 0)
    NumPut("UChar", 0, blend, 0)             ; BlendOp = AC_SRC_OVER
    NumPut("UChar", 0, blend, 1)             ; BlendFlags
    NumPut("UChar", CFG.alpha, blend, 2)     ; SourceConstantAlpha
    NumPut("UChar", 1, blend, 3)             ; AlphaFormat = AC_SRC_ALPHA

    DllCall("UpdateLayeredWindow", "Ptr", tagGui.Hwnd, "Ptr", g_hdcScreen, "Ptr", ptDst
          , "Ptr", sz, "Ptr", g_hdcMem, "Ptr", ptSrc, "UInt", 0, "Ptr", blend, "UInt", 2)
}

Cleanup(*) {
    global g_hbm, g_hbmBlank, g_hdcMem, g_hdcScreen, gdiToken
    TrayIme_Drop()
    if g_hbm
        DllCall("DeleteObject", "Ptr", g_hbm)
    if g_hbmBlank
        DllCall("DeleteObject", "Ptr", g_hbmBlank)
    if g_hdcMem
        DllCall("DeleteDC", "Ptr", g_hdcMem)
    if g_hdcScreen
        DllCall("ReleaseDC", "Ptr", 0, "Ptr", g_hdcScreen)
    if gdiToken
        DllCall("gdiplus\GdiplusShutdown", "Ptr", gdiToken)
}

OnExit(Cleanup)

; ---------------------------- 系统接口 ------------------------------------

; 取前景线程的焦点窗口 + 光标高度（GetGUIThreadInfo，跨进程可用）
; 注意：rcCaret 是相对该窗口的客户区坐标，不能用于屏幕定位，定位统一走 CaretGetPos
GetFocusAndCaretHeight(hwndFG, &caretH) {
    static GTI_SIZE    := (A_PtrSize = 8) ? 72 : 48
    static OFF_FOCUS   := (A_PtrSize = 8) ? 16 : 12
    static OFF_CARET   := (A_PtrSize = 8) ? 48 : 28
    static OFF_TOP     := (A_PtrSize = 8) ? 60 : 36
    static OFF_BOTTOM  := (A_PtrSize = 8) ? 68 : 44

    caretH := 0
    buf := Buffer(GTI_SIZE, 0)
    NumPut("UInt", GTI_SIZE, buf, 0)          ; cbSize

    if !DllCall("GetGUIThreadInfo", "UInt", 0, "Ptr", buf, "Int")
        return hwndFG

    if NumGet(buf, OFF_CARET, "Ptr") {
        h := NumGet(buf, OFF_BOTTOM, "Int") - NumGet(buf, OFF_TOP, "Int")
        if (h > 0 && h < 200)
            caretH := h
    }

    focus := NumGet(buf, OFF_FOCUS, "Ptr")
    return focus ? focus : hwndFG
}

; 判定输入法状态：IME_CMODE_NATIVE(0x0001) 为 1 即中文
GetIMEMode(hwnd) {
    if !hwnd
        return -1

    ; 主路径：读取该窗口输入上下文的转换状态
    hIMC := DllCall("imm32\ImmGetContext", "Ptr", hwnd, "Ptr")
    if hIMC {
        open := DllCall("imm32\ImmGetOpenStatus", "Ptr", hIMC, "Int")
        conv := 0
        sentence := 0
        DllCall("imm32\ImmGetConversionStatus", "Ptr", hIMC, "UInt*", &conv, "UInt*", &sentence, "Int")
        DllCall("imm32\ImmReleaseContext", "Ptr", hwnd, "Ptr", hIMC)
        return (open && (conv & 0x0001)) ? 1 : 0
    }

    ; 兜底：向默认 IME 窗口查询转换模式（部分第三方输入法不走上面的接口）
    hIMEWnd := DllCall("imm32\ImmGetDefaultIMEWnd", "Ptr", hwnd, "Ptr")
    if hIMEWnd {
        r := SendMsgTimeout(hIMEWnd, 0x0283, 0x0001, 0)   ; WM_IME_CONTROL / IMC_GETCONVERSIONMODE
        if r.ok
            return (r.res & 0x0001) ? 1 : 0
        ; 消息根本没送进去（提权窗口被 UIPI 拦截，GetLastError=5）：
        ; 这时 r.res 恒为 0，照收就会把「中文」误判成「英文」——任务管理器正是如此。
        ; 所以这里必须报「无法判定」，交给 TrayIme_Mode() 去读任务栏指示器。
    }

    return -1
}

; 带超时的 SendMessage。返回 {ok, res}：ok=false 表示消息未能送达
; （被 UIPI 拦截或对方无响应），此时 res 无意义，不能当作查询结果用。
SendMsgTimeout(hwnd, msg, wp, lp) {
    static SMTO_ABORTIFHUNG := 0x0002
    res := 0
    ok := DllCall("SendMessageTimeoutW", "Ptr", hwnd, "UInt", msg, "Ptr", wp, "Ptr", lp
                , "UInt", SMTO_ABORTIFHUNG, "UInt", 200, "Ptr*", &res)
    return {ok: ok ? true : false, res: res}
}

; ---------------------- 任务栏输入指示器（UIA 兜底） -----------------------
; 为什么需要：任务管理器这类提权程序的 IME 上下文普通权限拿不到，
; WM_IME_CONTROL 也会被 UIPI 拦掉（见上）。而任务栏右下角那个输入指示器
; 由 explorer.exe 托管、普通权限就能读，它的 UIA 名字会随当前焦点窗口的
; 输入法状态在「中文模式 / 英语模式」之间切换 —— 正好补上这个缺口。
;
; 用 UIA 的原始 vtable 调用（IUIAutomation / IUIAutomationElement），
; 不依赖任何外部库。元素只在第一次需要时查找一次，之后缓存复用；
; 读一次名字实测 <1ms，所以放在 80ms 的轮询里也没有负担。

CLSID_CUIAutomation := "{FF48DBA4-60EF-4201-AA87-54103EEF594E}"
IID_IUIAutomation   := "{30CBE57D-D9D0-452A-AB13-7AC5AC4825EE}"

UIA_Name         := 30005      ; UIA_NamePropertyId
TREE_DESCENDANTS := 4          ; TreeScope_Descendants

; 返回 1=中，0=英，-1=读不到
TrayIme_Mode() {
    global gIndEl, gIndNextTry, CFG
    if !CFG.trayFallback
        return -1

    if gIndEl {
        m := TrayIme_Parse(TrayIme_Name(gIndEl))
        if (m >= 0)
            return m
        TrayIme_Drop()                  ; 元素失效（explorer 重启、任务栏重排等），丢掉重找
    }

    if (A_TickCount < gIndNextTry)
        return -1
    gIndNextTry := A_TickCount + CFG.trayRetryMs

    gIndEl := TrayIme_Find()
    if !gIndEl
        return -1
    return TrayIme_Parse(TrayIme_Name(gIndEl))
}

TrayIme_Drop() {
    global gIndEl
    if gIndEl {
        UiaRelease(gIndEl)
        gIndEl := 0
    }
}

; 在任务栏（Shell_TrayWnd）子树里找输入指示器：名字里带「模式 / mode」的那个
TrayIme_Find() {
    global gUia, CLSID_CUIAutomation, IID_IUIAutomation, TREE_DESCENDANTS

    if !gUia {
        try gUia := ComObject(CLSID_CUIAutomation, IID_IUIAutomation)
        catch
            return 0
    }

    tray := DllCall("FindWindowW", "Str", "Shell_TrayWnd", "Ptr", 0, "Ptr")
    if !tray
        return 0

    root := 0
    if (UiaCall(gUia.Ptr, 6, "Ptr", tray, "Ptr*", &root) != 0 || !root)   ; ElementFromHandle
        return 0

    cond := 0
    if (UiaCall(gUia.Ptr, 21, "Ptr*", &cond) != 0 || !cond) {             ; CreateTrueCondition
        UiaRelease(root)
        return 0
    }

    arr := 0
    hr := UiaCall(root, 6, "Int", TREE_DESCENDANTS, "Ptr", cond, "Ptr*", &arr)   ; FindAll
    UiaRelease(cond)
    UiaRelease(root)
    if (hr != 0 || !arr)
        return 0

    n := 0
    UiaCall(arr, 3, "Int*", &n)                                          ; get_Length
    found := 0
    Loop n {
        el := 0
        if (UiaCall(arr, 4, "Int", A_Index - 1, "Ptr*", &el) != 0 || !el)  ; GetElement
            continue
        if (!found && TrayIme_Parse(TrayIme_Name(el)) >= 0)
            found := el
        else
            UiaRelease(el)
    }
    UiaRelease(arr)
    return found
}

TrayIme_Name(el) {
    global UIA_Name
    v := Buffer(24, 0)
    if (UiaCall(el, 10, "Int", UIA_Name, "Ptr", v) != 0)                 ; GetCurrentPropertyValue
        return ""
    if (NumGet(v, 0, "UShort") != 8)                                     ; 不是 VT_BSTR
        return ""
    p := NumGet(v, 8, "Ptr")
    s := p ? StrGet(p, "UTF-16") : ""
    if p
        DllCall("oleaut32\SysFreeString", "Ptr", p)
    return s
}

; 指示器名字 → 模式。名字形如「任务栏输入指示 中文模式 ...」
; 另一个同类元素是「任务栏输入指示 简体中文(中国大陆) 微软五笔 ...」，
; 它不含「模式」，所以不会被误判。
TrayIme_Parse(nm) {
    if (nm = "")
        return -1
    if (InStr(nm, "中文模式") || InStr(nm, "Chinese mode") || InStr(nm, "Chinese Mode"))
        return 1
    if (InStr(nm, "英语模式") || InStr(nm, "English mode") || InStr(nm, "English Mode"))
        return 0
    if (InStr(nm, "模式") || InStr(nm, "mode") || InStr(nm, "Mode")) {   ; 其他语言环境兜底
        if (InStr(nm, "指示") || InStr(nm, "ndicator")) {               ; 先确认是「输入指示器」那一项
            if InStr(nm, "中")
                return 1
            if InStr(nm, "英")
                return 0
        }
    }
    return -1
}

; 按 vtable 序号直接调用 COM 方法（AHK 里最省事，不必依赖类型库）
UiaCall(ptr, index, args*) {
    fn := NumGet(NumGet(ptr, 0, "Ptr"), index * A_PtrSize, "Ptr")
    params := ["Ptr", ptr]
    for a in args
        params.Push(a)
    params.Push("Int")
    return DllCall(fn, params*)
}

UiaRelease(p) {
    if !p
        return
    fn := NumGet(NumGet(p, 0, "Ptr"), 2 * A_PtrSize, "Ptr")
    DllCall(fn, "Ptr", p)
}