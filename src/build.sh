#!/bin/sh
# Cross-compile DeepseekHarness.exe (needs gcc-mingw-w64-x86-64 + python3)
set -e
cd "$(dirname "$0")"
x86_64-w64-mingw32-gcc -O2 -s -mconsole ctrlc.c -o ctrlc.exe          # Ctrl+C helper (embedded)
python3 embed.py                                                       # scripts + ctrlc.exe -> scripts.h
x86_64-w64-mingw32-windres app.rc -O coff -o app.res
x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -mwindows -static -s \
    launcher.c app.res -o ../DeepseekHarness.exe -lgdi32 -luser32 -lkernel32
cp ctrlc.exe ../ctrlc.exe
rm -f app.res
ls -la ../DeepseekHarness.exe ../ctrlc.exe
