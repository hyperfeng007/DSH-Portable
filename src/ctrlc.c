/* ctrlc.exe <pid> - deliver a real Ctrl+C to the (hidden) console of another process.
 * Used by Start-DSH.ps1 so dsh can shut down gracefully (it handles SIGINT); the
 * launcher force-kills whatever is still alive a few seconds later.
 * exit codes: 0 sent, 2 usage, 3 cannot attach (no console / gone), 4 send failed */
#include <windows.h>
#include <stdlib.h>
int main(int argc, char** argv)
{
    if (argc < 2) return 2;
    DWORD pid = (DWORD)strtoul(argv[1], NULL, 10);
    if (!pid) return 2;
    FreeConsole();
    if (!AttachConsole(pid)) return 3;
    SetConsoleCtrlHandler(NULL, TRUE);            /* do not kill ourselves */
    BOOL ok = GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0);
    Sleep(300);
    FreeConsole();
    return ok ? 0 : 4;
}
