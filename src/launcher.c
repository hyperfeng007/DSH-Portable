/*
 * DeepseekHarness.exe - DSH-Portable launcher
 *
 *   - no console window, ever (the orchestrator + dsh + npm all run hidden)
 *   - shows a small progress window with the current startup step
 *   - first run: installs the runtime; later runs: straight to the app window
 *   - closing the app window stops every process that was started
 *   - second click while running: brings the app window to the front
 *
 * All the real work is done by Start-DSH.ps1 (embedded below via scripts.h and
 * re-written next to the exe on every launch). The exe and the script talk
 * through three small files in the same folder:
 *     progress.txt  current step number (1..8)
 *     ready.flag    app window is on screen -> progress window closes
 *     error.txt     UTF-8 error text     -> progress window turns into a message box
 *     run.lock      pid= / dsh= / browser=  while a session is running
 * ctrlc.exe (also embedded) delivers a real Ctrl+C to dsh so it can shut down
 * gracefully before anything left over is force-killed.
 */
#define _WIN32_WINNT 0x0601
#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#include <windows.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include "scripts.h"

#define APP_TITLE   L"DeepSeek Harness"
#define STEP_COUNT  8
#define TIMER_MS    80
#define MAX_WAIT_MS (25 * 60 * 1000)   /* first install on a slow network */

static WCHAR  g_dir[MAX_PATH];
static HANDLE g_hOrch = NULL;
static double g_progress = 0.0;
static int    g_step = 0;
static int    g_ready = 0;
static int    g_error = 0;
static WCHAR  g_errmsg[4096];
static DWORD  g_start = 0;
static double g_scale = 1.0;
static int    g_anim = 0;

static const WCHAR* g_steps[STEP_COUNT] = {
    L"正在准备...",
    L"正在导入系统网络代理...",
    L"正在检查运行环境...",
    L"首次安装：正在解压 Node.js 运行时...",
    L"首次安装：正在下载 DeepSeek Harness（需联网，约 1~3 分钟）...",
    L"正在启动 DeepSeek Harness 服务...",
    L"正在等待服务就绪...",
    L"正在打开应用窗口..."
};

/* ------------------------------------------------------------ small utils */
static int S(double v) { return (int)(v * g_scale + 0.5); }

static void PathIn(WCHAR* out, const WCHAR* name)
{
    wsprintfW(out, L"%s%s", g_dir, name);
}

static void LogA(const char* msg)
{
    WCHAR p[MAX_PATH];
    PathIn(p, L"DeepseekHarness.log");
    HANDLE h = CreateFileW(p, FILE_APPEND_DATA, FILE_SHARE_READ, NULL,
                           OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return;
    SYSTEMTIME st; GetLocalTime(&st);
    char line[512];
    wsprintfA(line, "%04d-%02d-%02d %02d:%02d:%02d  %s\r\n",
              st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, msg);
    DWORD w = 0;
    WriteFile(h, line, (DWORD)lstrlenA(line), &w, NULL);
    CloseHandle(h);
}

static int FileExists(const WCHAR* p)
{
    DWORD a = GetFileAttributesW(p);
    return a != INVALID_FILE_ATTRIBUTES && !(a & FILE_ATTRIBUTE_DIRECTORY);
}

static int WriteScript(const WCHAR* name, const char* content, int bom)
{
    WCHAR p[MAX_PATH];
    PathIn(p, name);
    HANDLE h = CreateFileW(p, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS,
                           FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return 0;
    DWORD w = 0;
    if (bom) {
        static const unsigned char b[3] = {0xEF, 0xBB, 0xBF};
        WriteFile(h, b, 3, &w, NULL);
    }
    /* normalise to CRLF: cmd.exe wants it, PowerShell does not mind */
    const char* s = content;
    const char* seg = s;
    while (*s) {
        if (*s == '\n') {
            if (s > seg) WriteFile(h, seg, (DWORD)(s - seg), &w, NULL);
            WriteFile(h, "\r\n", 2, &w, NULL);
            seg = s + 1;
        }
        s++;
    }
    if (s > seg) WriteFile(h, seg, (DWORD)(s - seg), &w, NULL);
    CloseHandle(h);
    return 1;
}

static int WriteBinary(const WCHAR* name, const unsigned char* data, DWORD len)
{
    WCHAR p[MAX_PATH];
    PathIn(p, name);
    /* skip when identical size + present (keeps antivirus quiet on every launch) */
    WIN32_FILE_ATTRIBUTE_DATA fa;
    if (GetFileAttributesExW(p, GetFileExInfoStandard, &fa) && fa.nFileSizeHigh == 0 && fa.nFileSizeLow == len)
        return 1;
    HANDLE h = CreateFileW(p, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS,
                           FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return 0;
    DWORD w = 0;
    WriteFile(h, data, len, &w, NULL);
    CloseHandle(h);
    return w == len;
}

static DWORD ReadSmall(const WCHAR* name, char* buf, DWORD cap)
{
    WCHAR p[MAX_PATH];
    PathIn(p, name);
    HANDLE h = CreateFileW(p, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           NULL, OPEN_EXISTING, 0, NULL);
    if (h == INVALID_HANDLE_VALUE) return 0;
    DWORD r = 0;
    ReadFile(h, buf, cap - 1, &r, NULL);
    CloseHandle(h);
    buf[r] = 0;
    return r;
}

static int ReadStep(void)
{
    char buf[32];
    if (!ReadSmall(L"progress.txt", buf, sizeof(buf))) return g_step;
    int v = atoi(buf);
    return (v >= 1 && v <= STEP_COUNT) ? v : g_step;
}

static int ReadErrorText(void)
{
    char buf[3000];
    DWORD n = ReadSmall(L"error.txt", buf, sizeof(buf));
    if (!n) return 0;
    const char* s = buf;
    if (n >= 3 && (unsigned char)s[0] == 0xEF && (unsigned char)s[1] == 0xBB && (unsigned char)s[2] == 0xBF) s += 3;
    int len = MultiByteToWideChar(CP_UTF8, 0, s, -1, g_errmsg, 3500);
    if (len <= 0) lstrcpyW(g_errmsg, L"启动失败。");
    return 1;
}

static void CheckFlags(void)
{
    WCHAR p[MAX_PATH];
    PathIn(p, L"ready.flag");
    if (FileExists(p)) g_ready = 1;
    PathIn(p, L"error.txt");
    if (FileExists(p) && ReadErrorText()) g_error = 1;
}

static void DeleteIn(const WCHAR* name)
{
    WCHAR p[MAX_PATH];
    PathIn(p, name);
    DeleteFileW(p);
}

/* ------------------------------------------------------------ already running? */
typedef struct { DWORD pid; HWND found; } FindCtx;

static BOOL CALLBACK EnumProc(HWND h, LPARAM lp)
{
    FindCtx* c = (FindCtx*)lp;
    if (!IsWindowVisible(h)) return TRUE;
    if (GetWindow(h, GW_OWNER) != NULL) return TRUE;
    WCHAR cls[64] = {0};
    GetClassNameW(h, cls, 64);
    if (wcsncmp(cls, L"Chrome_WidgetWin", 16) != 0) return TRUE;
    if (c->pid != 0) {
        DWORD wp = 0;
        GetWindowThreadProcessId(h, &wp);
        if (wp == c->pid) { c->found = h; return FALSE; }
        return TRUE;
    }
    WCHAR title[256] = {0};
    GetWindowTextW(h, title, 256);
    if (wcsstr(title, APP_TITLE) != NULL) { c->found = h; return FALSE; }
    return TRUE;
}

static int FocusAppWindow(DWORD browserPid)
{
    FindCtx c;
    c.pid = browserPid; c.found = NULL;
    if (browserPid) EnumWindows(EnumProc, (LPARAM)&c);
    if (!c.found) { c.pid = 0; EnumWindows(EnumProc, (LPARAM)&c); }
    if (!c.found) return 0;
    if (IsIconic(c.found)) ShowWindow(c.found, SW_RESTORE);
    SetForegroundWindow(c.found);
    return 1;
}

static int IsLauncherAlive(DWORD pid)
{
    if (!pid) return 0;
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!h) return 0;
    int alive = 0;
    DWORD code = 0;
    if (GetExitCodeProcess(h, &code) && code == STILL_ACTIVE) {
        WCHAR img[MAX_PATH]; DWORD n = MAX_PATH;
        alive = 1;
        if (QueryFullProcessImageNameW(h, 0, img, &n)) {
            _wcslwr(img);
            if (!wcsstr(img, L"powershell")) alive = 0;   /* pid was recycled by something else */
        }
    }
    CloseHandle(h);
    return alive;
}

/* returns 1 when a session is running (and handled the click) */
static int HandleAlreadyRunning(void)
{
    char buf[512];
    if (!ReadSmall(L"run.lock", buf, sizeof(buf))) return 0;
    DWORD pid = 0, bpid = 0;
    const char* p = strstr(buf, "pid=");
    if (p) pid = (DWORD)atol(p + 4);
    const char* b = strstr(buf, "browser=");
    if (b) bpid = (DWORD)atol(b + 8);
    if (!IsLauncherAlive(pid)) { DeleteIn(L"run.lock"); return 0; }   /* stale */
    if (FocusAppWindow(bpid)) { LogA("already running - focused app window"); return 1; }
    LogA("already running - window not found yet");
    MessageBoxW(NULL,
        L"DeepSeek Harness 已在运行或正在启动中，请稍候。\n\n"
        L"如果确认它没有在运行，请删除同目录下的 run.lock 后再试。",
        APP_TITLE, MB_ICONINFORMATION | MB_OK | MB_TOPMOST);
    return 1;
}

/* ------------------------------------------------------------ progress window */
static void Paint(HWND hwnd)
{
    PAINTSTRUCT ps;
    HDC hdc = BeginPaint(hwnd, &ps);
    RECT rc; GetClientRect(hwnd, &rc);

    /* double buffer */
    HDC mem = CreateCompatibleDC(hdc);
    HBITMAP bmp = CreateCompatibleBitmap(hdc, rc.right, rc.bottom);
    HGDIOBJ oldbmp = SelectObject(mem, bmp);

    HBRUSH bg = CreateSolidBrush(RGB(0x14, 0x17, 0x1F));
    FillRect(mem, &rc, bg);
    DeleteObject(bg);
    HBRUSH frame = CreateSolidBrush(RGB(0x2E, 0x34, 0x44));
    FrameRect(mem, &rc, frame);
    DeleteObject(frame);

    SetBkMode(mem, TRANSPARENT);
    HFONT f1 = CreateFontW(-S(19), 0, 0, 0, FW_SEMIBOLD, 0, 0, 0, DEFAULT_CHARSET,
                           OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                           DEFAULT_PITCH | FF_DONTCARE, L"Microsoft YaHei UI");
    HFONT f2 = CreateFontW(-S(14), 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET,
                           OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                           DEFAULT_PITCH | FF_DONTCARE, L"Microsoft YaHei UI");

    /* accent dot + title */
    HBRUSH dot = CreateSolidBrush(RGB(0x4D, 0x6B, 0xFE));
    RECT rd = {S(20), S(24), S(20) + S(10), S(24) + S(10)};
    FillRect(mem, &rd, dot);
    DeleteObject(dot);

    HGDIOBJ oldf = SelectObject(mem, f1);
    SetTextColor(mem, RGB(0xF2, 0xF4, 0xF8));
    RECT rt = {S(38), S(14), rc.right - S(20), S(44)};
    DrawTextW(mem, L"正在启动 DeepSeek Harness，请稍候...", -1, &rt, DT_SINGLELINE | DT_LEFT | DT_VCENTER | DT_END_ELLIPSIS);

    /* step line + elapsed seconds */
    SelectObject(mem, f2);
    SetTextColor(mem, RGB(0xA6, 0xAD, 0xBB));
    int idx = (g_step >= 1 && g_step <= STEP_COUNT) ? g_step - 1 : 0;
    DWORD el = (GetTickCount() - g_start) / 1000;
    const WCHAR* stepText = g_ready ? L"完成，正在打开窗口..." : g_steps[idx];
    RECT rs = {S(38), S(48), rc.right - S(20), S(70)};
    DrawTextW(mem, stepText, -1, &rs, DT_SINGLELINE | DT_LEFT | DT_VCENTER | DT_END_ELLIPSIS);

    /* bar (leaves room on the right for "62% · 95 秒") */
    int bx = S(20), by = S(86), bw = rc.right - S(20) - S(112) - bx, bh = S(7);
    RECT ro = {bx, by, bx + bw, by + bh};
    HBRUSH bo = CreateSolidBrush(RGB(0x27, 0x2C, 0x38));
    FillRect(mem, &ro, bo);
    DeleteObject(bo);
    int fw = (int)(bw * g_progress / 100.0);
    if (fw > 0) {
        RECT rf = {bx, by, bx + fw, by + bh};
        HBRUSH bf = CreateSolidBrush(RGB(0x4D, 0x6B, 0xFE));
        FillRect(mem, &rf, bf);
        DeleteObject(bf);
        if (!g_ready) {
            /* moving highlight so a long step still looks alive */
            int band = S(56);
            int span = fw + band;
            int x = bx - band + (int)(((long long)g_anim * S(5)) % span);
            RECT hi = {x, by, x + band, by + bh};
            RECT clip;
            if (IntersectRect(&clip, &hi, &rf)) {
                HBRUSH bh2 = CreateSolidBrush(RGB(0x8E, 0xA3, 0xFF));
                FillRect(mem, &clip, bh2);
                DeleteObject(bh2);
            }
        }
    }
    /* percent + elapsed, right of the bar */
    WCHAR pct[48];
    if (el >= 3) wsprintfW(pct, L"%d%% · %u 秒", (int)g_progress, (unsigned)el);
    else         wsprintfW(pct, L"%d%%", (int)g_progress);
    SetTextColor(mem, RGB(0x7C, 0x85, 0x97));
    RECT rp = {bx + bw + S(8), by - S(9), rc.right - S(18), by + bh + S(9)};
    DrawTextW(mem, pct, -1, &rp, DT_SINGLELINE | DT_RIGHT | DT_VCENTER);

    SelectObject(mem, oldf);
    DeleteObject(f1);
    DeleteObject(f2);

    BitBlt(hdc, 0, 0, rc.right, rc.bottom, mem, 0, 0, SRCCOPY);
    SelectObject(mem, oldbmp);
    DeleteObject(bmp);
    DeleteDC(mem);
    EndPaint(hwnd, &ps);
}

static void CloseProgress(HWND hwnd)
{
    KillTimer(hwnd, 1);
    DestroyWindow(hwnd);
}

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    switch (msg) {
    case WM_PAINT:
        Paint(hwnd);
        return 0;
    case WM_ERASEBKGND:
        return 1;
    case WM_TIMER: {
        g_anim++;
        g_step = ReadStep();
        CheckFlags();
        if (g_error) { CloseProgress(hwnd); return 0; }

        double target = g_ready ? 100.0 : (double)g_step * (100.0 / STEP_COUNT);
        if (!g_ready && target > 96.0) target = 96.0;
        if (g_progress < target) {
            g_progress += g_ready ? 2.5 : 1.2;
            if (g_progress > target) g_progress = target;
        }
        if (g_ready && g_progress >= 99.5) { CloseProgress(hwnd); return 0; }

        /* orchestrator died without telling us anything */
        if (g_hOrch && WaitForSingleObject(g_hOrch, 0) == WAIT_OBJECT_0) {
            Sleep(300);
            CheckFlags();
            if (!g_ready && !g_error) {
                g_error = 1;
                lstrcpyW(g_errmsg,
                    L"启动程序意外退出。\n\n请查看同目录下的 Start-DSH.log 和 dsh-web.log。\n"
                    L"如果是杀毒软件拦截了 PowerShell，请先放行本文件夹。");
            }
            CloseProgress(hwnd);
            return 0;
        }
        if (GetTickCount() - g_start > MAX_WAIT_MS) {
            g_error = 1;
            lstrcpyW(g_errmsg, L"启动超时。\n\n请查看同目录下的 Start-DSH.log 和 dsh-web.log。");
            CloseProgress(hwnd);
            return 0;
        }
        InvalidateRect(hwnd, NULL, FALSE);
        return 0;
    }
    case WM_KEYDOWN:
        if (wp == VK_ESCAPE) { CloseProgress(hwnd); return 0; }
        break;
    case WM_LBUTTONDOWN:
        /* let the user drag the little window around */
        SendMessageW(hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static void ShowProgress(HINSTANCE hInst)
{
    WNDCLASSEXW wc;
    ZeroMemory(&wc, sizeof(wc));
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hInst;
    wc.hCursor = LoadCursorW(NULL, (LPCWSTR)IDC_ARROW);
    wc.hIcon = LoadIconW(hInst, MAKEINTRESOURCEW(1));
    wc.lpszClassName = L"DSHPortableLauncherWnd";
    RegisterClassExW(&wc);

    int sw = GetSystemMetrics(SM_CXSCREEN);
    int sh = GetSystemMetrics(SM_CYSCREEN);
    int ww = S(540), wh = S(114);
    int x = (sw - ww) / 2, y = (sh - wh) / 2 - S(40);

    HWND hwnd = CreateWindowExW(WS_EX_TOPMOST | WS_EX_TOOLWINDOW, wc.lpszClassName,
                                APP_TITLE, WS_POPUP,
                                x, y, ww, wh, NULL, NULL, hInst, NULL);
    if (!hwnd) return;
    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);
    SetTimer(hwnd, 1, TIMER_MS, NULL);

    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
}

/* ------------------------------------------------------------ main */
int WINAPI WinMain(HINSTANCE hInstance, HINSTANCE hPrevInstance, LPSTR lpCmdLine, int nCmdShow)
{
    (void)hPrevInstance; (void)lpCmdLine; (void)nCmdShow;

    DWORD len = GetModuleFileNameW(NULL, g_dir, MAX_PATH);
    if (len == 0 || len >= MAX_PATH) return 1;
    int i = (int)len - 1;
    while (i >= 0 && g_dir[i] != L'\\') i--;
    if (i < 0) return 1;
    g_dir[i + 1] = L'\0';

    SetProcessDPIAware();
    {
        HDC hdc = GetDC(NULL);
        int dpi = GetDeviceCaps(hdc, LOGPIXELSX);
        ReleaseDC(NULL, hdc);
        if (dpi > 0) g_scale = dpi / 96.0;
    }

    /* a session is already running -> just bring its window to the front */
    if (HandleAlreadyRunning()) return 0;

    HANDLE mtx = CreateMutexW(NULL, TRUE, L"DSHPortableLauncher");
    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        MessageBoxW(NULL,
            L"DeepSeek Harness 正在启动中，请稍候，不要重复点击。",
            APP_TITLE, MB_ICONINFORMATION | MB_OK | MB_TOPMOST);
        return 0;
    }

    LogA("== start ==");

    if (!WriteScript(L"Start-DSH.ps1", SCRIPT_START_DSH_PS1, 1) ||
        !WriteScript(L"Install-DSH.bat", SCRIPT_INSTALL_DSH_BAT, 0) ||
        !WriteScript(L"Update-DSH.bat", SCRIPT_UPDATE_DSH_BAT, 0) ||
        !WriteScript(L"DSH-Terminal.bat", SCRIPT_DSH_TERMINAL_BAT, 0) ||
        !WriteScript(L"Stop-DSH.bat", SCRIPT_STOP_DSH_BAT, 0) ||
        !WriteBinary(L"ctrlc.exe", BIN_CTRLC_EXE, BIN_CTRLC_EXE_LEN))
    {
        LogA("FAIL write scripts");
        MessageBoxW(NULL,
            L"无法写入启动脚本。\n\n请把整个文件夹放在可写位置（U 盘、D 盘均可，不要放在 C:\\Program Files），再双击一次。\n"
            L"详情见同目录 DeepseekHarness.log。",
            APP_TITLE, MB_ICONERROR | MB_OK | MB_TOPMOST);
        ReleaseMutex(mtx); CloseHandle(mtx);
        return 2;
    }
    DeleteIn(L"progress.txt");
    DeleteIn(L"ready.flag");
    DeleteIn(L"error.txt");
    /* files from the old (v1, console based) package layout - no longer used */
    DeleteIn(L"LaunchDSH.bat");
    DeleteIn(L"Open-UI.ps1");
    DeleteIn(L"Start-DSH.bat");

    /* full path first (PATH is sometimes mangled on managed PCs), bare name as fallback */
    WCHAR ps[MAX_PATH] = L"powershell.exe";
    {
        WCHAR sysdir[MAX_PATH];
        if (GetSystemDirectoryW(sysdir, MAX_PATH)) {
            WCHAR cand[MAX_PATH];
            wsprintfW(cand, L"%s\\WindowsPowerShell\\v1.0\\powershell.exe", sysdir);
            if (FileExists(cand)) lstrcpyW(ps, cand);
        }
    }
    WCHAR cmdline[1024];
    wsprintfW(cmdline,
        L"\"%s\" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%sStart-DSH.ps1\"",
        ps, g_dir);

    STARTUPINFOW si; PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si)); si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW; si.wShowWindow = SW_HIDE;
    ZeroMemory(&pi, sizeof(pi));
    if (!CreateProcessW(NULL, cmdline, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, g_dir, &si, &pi)) {
        LogA("FAIL launch powershell");
        MessageBoxW(NULL,
            L"无法启动 PowerShell（Windows 自带组件）。\n\n请查看同目录下的 DeepseekHarness.log。",
            APP_TITLE, MB_ICONERROR | MB_OK | MB_TOPMOST);
        ReleaseMutex(mtx); CloseHandle(mtx);
        return 3;
    }
    CloseHandle(pi.hThread);
    g_hOrch = pi.hProcess;
    LogA("OK orchestrator started (hidden)");

    g_start = GetTickCount();
    ShowProgress(hInstance);

    if (g_error) {
        LogA("ERROR shown to user");
        WCHAR full[4600];
        _snwprintf(full, 4599, L"%s\n\n日志：Start-DSH.log、dsh-web.log（与本程序同目录）", g_errmsg);
        full[4599] = 0;
        MessageBoxW(NULL, full, APP_TITLE, MB_ICONERROR | MB_OK | MB_TOPMOST);
        DeleteIn(L"error.txt");
    } else {
        LogA("OK app window up");
    }
    DeleteIn(L"ready.flag");
    DeleteIn(L"progress.txt");

    CloseHandle(g_hOrch);
    ReleaseMutex(mtx); CloseHandle(mtx);
    return g_error ? 4 : 0;
}
