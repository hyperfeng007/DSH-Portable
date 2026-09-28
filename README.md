# DSH-Portable

**DeepSeek Harness 便携启动器 —— 免安装 · 零配置 · 双击即用 · 无黑框**

> 把命令行 AI 智能体 [DeepSeek Harness](https://www.npmjs.com/package/@deepseek-ai/dsh)(`dsh`)连同 Node.js 运行时装进一个文件夹:
> 下载 → 解压 → 双击 `DeepseekHarness.exe`。首次运行自动安装(带进度条),之后秒开;
> 关掉应用窗口,所有后台进程自动退出;宿主机零残留,可直接放 U 盘随身携带。

**[⬇ 下载最新版(Releases)](../../releases)** —— 解压即用,无需任何配置。

---

## 为什么需要它

dsh 是一个强大的命令行 AI 智能体,但对普通 Windows 用户有三个门槛:要先装 Node.js 并会命令行;启动时黑窗滚动、没有反馈,不知道它在干什么;公司网络有代理时 npm 装不上、模型连不上。

DSH-Portable 把这些全部自动化:

| 特性 | 说明 |
|---|---|
| 🖱️ 双击即用 | 无需安装 Node.js、无需命令行。首次运行自动安装(约 1~3 分钟,需联网),之后每次启动几秒直达应用窗口 |
| 📊 启动进度条 | 全程无黑色控制台窗口;居中迷你进度窗显示当前步骤、百分比、已用时间 |
| 🚪 关窗即退 | 关闭应用窗口 → 先给 dsh 发真正的 Ctrl+C 优雅退出,5 秒未退自动强制结束,并清扫残留 node 进程 |
| 🔌 自动代理 | 自动读取系统代理(Internet 选项 / PAC / 环境变量 / WinHTTP)注入 dsh、npm 与 Node;`NODE_USE_SYSTEM_CA=1` 信任 Windows 证书库,企业 TLS 解密网络不报证书错误 |
| 🧳 完全便携 | 不写注册表、不改 PATH、不装服务、不进 C 盘;密钥/会话/设置/浏览器数据全在本文件夹内,删除文件夹 = 彻底卸载 |
| 🔁 防重复启动 | 已在运行时再次双击,自动把现有窗口拉到前台 |
| ❌ 失败可见 | 启动失败直接弹窗给出原因和对应日志文件名,不用去黑窗里翻 |
| 🗂️ 独立浏览器 | 应用窗口使用本文件夹内的独立浏览器配置(`browser-profile\`),可跟踪、零残留,不影响电脑上的 Edge/Chrome |

## 快速开始

1. 从 [Releases](../../releases) 下载 `DSH-Portable.zip`,解压到任意位置(U 盘、D 盘均可;路径建议全英文,如 `D:\DSH\`)。
2. 双击 `DeepseekHarness.exe`(鲸鱼图标)。
   - **首次**:进度条显示"首次安装:正在解压 Node.js…"、"正在下载 DeepSeek Harness…",完成后自动弹出应用窗口;
   - **之后**:几秒直达。
3. 在应用里:选择工作区(建议选本文件夹的 `workspace\`)→ 设置里填入 DeepSeek API Key(`sk-` 开头)→ 开始使用。
4. 用完直接关窗口即可,U 盘可安全弹出。

> 💡 双击时若弹出"Windows 已保护你的电脑" → 更多信息 → 仍要运行。exe 未购买代码签名证书,属正常现象。

## 各文件作用

| 文件 | 作用 |
|---|---|
| `DeepseekHarness.exe` | ★ 主入口,双击即用。每次启动自动重新生成下面 5 个脚本和 `ctrlc.exe`,所以**升级只需覆盖这一个 exe** |
| `Start-DSH.ps1` | 后台编排脚本(代理导入、安装、启动 dsh、开窗口、监控、清理),由 exe 隐藏调用 |
| `Install-DSH.bat` | 预先安装(有命令行输出,给想提前装好/看细节的人用) |
| `Update-DSH.bat` | 一键升级 dsh 到最新版(先关掉正在运行的窗口) |
| `Stop-DSH.bat` | 强制停止:万一有残留进程,双击一次全部清掉 |
| `DSH-Terminal.bat` | 命令行模式(自动带上代理和环境变量,`dsh` / `node` / `npm` 可直接用) |
| `ctrlc.exe` | 14 KB 小助手:关窗口时给 dsh 发真正的 Ctrl+C 让它优雅退出 |
| `使用说明.txt` | 给最终用户的一页纸说明 |
| `node-v22.23.2-win-x64.zip` | 预置的 Node.js 便携运行时(免下载) |
| `src\` `assets\` | exe 源码(C + 脚本 + 构建脚本)与图标素材 |

运行后自动产生(都在本文件夹内):`node\` 运行时、`dsh\` 程序、`npm-cache\`、`dsh-home\` 数据、`workspace\` 工作区、`browser-profile\` 浏览器配置、`temp\`,以及日志 `DeepseekHarness.log`、`Start-DSH.log`、`dsh-web.log`、`npm-install.log`。

## 网络代理(公司网络 / 企业环境)

dsh 内置的 `dsh-http-proxy` 只读 `http_proxy / https_proxy / no_proxy` 环境变量,**不读 Windows 系统代理**,也不支持 SOCKS / PAC。所以启动器每次启动按下面顺序解析一次,翻译成 `http://` 形式注入给 dsh、npm 和 Node:

1. Internet 选项里的手动代理(Clash / V2Ray 等的"系统代理"开关设的就是这个),含"跳过列表"→ `NO_PROXY`
2. PAC 脚本 / 自动检测(WPAD):让 Windows 自己的代理引擎对 `api.deepseek.com`、`registry.npmjs.org` 解析出实际代理地址
3. 已存在的 `HTTP_PROXY / HTTPS_PROXY / ALL_PROXY` 环境变量
4. 机器级 WinHTTP 代理(`netsh winhttp set proxy`)

另外始终设置 `NODE_USE_SYSTEM_CA=1`(Node 22.19+),让 Node 信任 Windows 证书库——公司里做 TLS 解密的代理不会报证书错误。

- 想手动指定:在 `dsh-home\.env` 里写 `HTTPS_PROXY=http://host:port`,启动器发现后就不再自动导入(dsh 自己会读这个文件)。
- 想彻底关闭自动导入:在 `dsh-home\` 下新建空文件 `no-proxy-import.txt`。
- 实际用了哪个代理,看 `Start-DSH.log` 里的 `proxy:` 一行(账号密码会打码)。
- SOCKS 代理会被忽略(dsh 不支持),请改用代理软件的 HTTP 端口。

## 数据存储位置(关键)

| 数据 | 位置 |
|---|---|
| API Key(明文) | `dsh-home\.credentials.yaml` |
| 会话记录 / 设置 / 插件 | `dsh-home\` |
| 浏览器窗口的配置与缓存 | `browser-profile\`(独立于电脑上的 Edge / Chrome) |
| npm 缓存 | `npm-cache\` |
| 智能体生成的文件 | `workspace\` |

全部在本文件夹内;删除整个文件夹 = 彻底卸载,宿主零残留。唯一微量痕迹:Windows Prefetch 几 KB 缓存(可忽略)。

## 常见问题

- **双击 exe 弹"Windows 已保护你的电脑"** → 更多信息 → 仍要运行(未买数字签名,属正常)。
- **进度条一直停在"正在下载 DeepSeek Harness"** → 网络慢或代理不通;最长等 25 分钟会自动报错。看 `npm-install.log` 末尾;公司网络请确认 Internet 选项里的代理已开启。
- **弹出"服务启动超时 / 立即退出"** → 看 `dsh-web.log`;常见于 `dsh\` 目录损坏,双击 `Update-DSH.bat` 重装即可。
- **关掉窗口后想确认没残留** → 任务管理器里不应再有本文件夹路径下的 `node.exe`;不放心就双击 `Stop-DSH.bat`。
- **提示"已在运行或正在启动中"但没看到窗口** → 等几秒再点一次;确认没在运行时删掉 `run.lock`。
- **没装 Edge / Chrome** → 会用默认浏览器打开(此时关窗口靠标题识别,仍能自动退出)。
- **dsh 版本** → 发布时 npm `latest` 为 `0.1.5-rc.2`(开发者预览版),`Update-DSH.bat` 随时升级。

## 从源码构建

```
cd src
./build.sh          # 需要 gcc-mingw-w64-x86-64 + python3(Linux/WSL 交叉编译)
```

`embed.py` 会把 `Start-DSH.ps1`、4 个 `.bat` 和 `ctrlc.exe` 打进 `scripts.h`,exe 启动时重新写出它们,所以**只需要分发 exe 就能升级启动逻辑**。exe 与脚本之间通过同目录的小文件通信:`progress.txt`(步骤号 1~8)、`ready.flag`(窗口已出现)、`error.txt`(UTF-8 错误文本)、`run.lock`(运行中的 pid)。

## 许可证与声明

- 本仓库启动器源码:**[MIT](LICENSE)**
- Node.js:官方发行 zip 按原样随包分发,许可见 zip 内 LICENSE(MIT 及第三方条款)
- DeepSeek Harness(`@deepseek-ai/dsh`):MIT,由用户首次运行时经 npm 自动下载安装,本仓库不含其代码
- 本项目为社区第三方便携化封装,**与 DeepSeek 官方无关**;DeepSeek 及相关商标归其所有者
- 请遵守 DeepSeek API 服务条款使用;请妥善保管自己的 API Key

---

## English Summary

DSH-Portable is an unofficial, zero-install portable launcher for **DeepSeek Harness (`dsh`)**, a command-line AI agent. Download the zip from [Releases](../../releases), unzip it anywhere (a USB stick works), and double-click `DeepseekHarness.exe`. It then:

- silently installs Node.js and `dsh` on first run, showing a small progress dialog (no console windows, ever);
- launches the dsh web UI as an app window using a folder-local browser profile;
- imports your system proxy (manual / PAC / WPAD / env vars / WinHTTP) into dsh, npm and Node, and trusts the Windows CA store — so it works behind corporate TLS-intercepting proxies;
- kills every process it started the moment you close the app window (graceful Ctrl+C first, force-kill after 5 s);
- leaves zero residue on the host: no registry, no PATH changes, no services — all data (API key, sessions, browser profile) stays inside the folder. Delete the folder = fully uninstalled.

Build from source: `cd src && ./build.sh` (needs `gcc-mingw-w64-x86-64` + `python3`). MIT licensed.
