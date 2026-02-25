# TypeClipboard.ps1
# Ctrl+C로 복사한 클립보드 텍스트를 3초 후 활성 커서 위치에 "타이핑"으로 입력 (Ctrl+V 사용 안 함)
# 추가 설치 불필요 / 한글 포함 유니코드 입력 지원(SendInput)

param(
    [int]$StartDelaySec = 3,     # 실행 후 대기(초)
    [int]$CharDelayMs   = 12,    # 글자 간 딜레이(ms) - 너무 빠르면 20~40으로 올리세요
    [ValidateSet('Enter','Space','Ignore')]
    [string]$NewlineMode = 'Enter',   # 줄바꿈 처리: Enter(기본) / Space / Ignore
    [switch]$TabsToSpaces,       # 탭을 공백으로 바꿀지
    [int]$TabSpaces = 4
)

function Convert-BoundParametersToArgumentList {
    param(
        [System.Collections.IDictionary]$BoundParameters
    )

    $argumentList = @()

    foreach ($entry in $BoundParameters.GetEnumerator()) {
        $name = "-$($entry.Key)"
        $value = $entry.Value

        if ($value -is [System.Management.Automation.SwitchParameter]) {
            if ($value.IsPresent) {
                $argumentList += $name
            }
            continue
        }

        $argumentList += $name
        $argumentList += [string]$value
    }

    return $argumentList
}

# --- STA 보장(클립보드 접근 안정성) ---
try {
    if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA' -and $PSCommandPath) {
        $ps51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $relaunchArgs = @(
            '-NoProfile','-ExecutionPolicy','Bypass','-STA','-File',$PSCommandPath
        ) + (Convert-BoundParametersToArgumentList -BoundParameters $PSBoundParameters)

        if (Test-Path $ps51) {
            Start-Process -FilePath $ps51 -ArgumentList $relaunchArgs
            exit
        }

        $currentShellPath = (Get-Process -Id $PID).Path
        if ($currentShellPath) {
            Start-Process -FilePath $currentShellPath -ArgumentList $relaunchArgs
            exit
        }
    }
} catch { }

# --- 클립보드 읽기 ---
$text = $null
try { $text = Get-Clipboard -Raw } catch { }

if ([string]::IsNullOrEmpty($text)) {
    try {
        Add-Type -AssemblyName PresentationCore | Out-Null
        $text = [System.Windows.Clipboard]::GetText()
    } catch { }
}

if ([string]::IsNullOrEmpty($text)) {
    Write-Host "클립보드가 비어있습니다. (Ctrl+C 후 다시 실행하세요.)"
    exit 1
}

# 탭 처리 옵션
if ($TabsToSpaces) {
    $text = $text -replace "`t", (' ' * [Math]::Max(1,$TabSpaces))
}

# 줄바꿈 정규화 (\r\n, \r -> \n)
$text = $text -replace "`r`n", "`n"
$text = $text -replace "`r", "`n"

# --- SendInput (Unicode + VK Enter/Tab) ---
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Threading;

public static class Typer {
    [StructLayout(LayoutKind.Sequential)]
    struct INPUT {
        public uint type;
        public InputUnion U;
    }

    [StructLayout(LayoutKind.Explicit)]
    struct InputUnion {
        [FieldOffset(0)] public KEYBDINPUT ki;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    const uint INPUT_KEYBOARD     = 1;
    const uint KEYEVENTF_KEYUP    = 0x0002;
    const uint KEYEVENTF_UNICODE  = 0x0004;

    const ushort VK_RETURN = 0x0D;
    const ushort VK_TAB    = 0x09;

    [DllImport("user32.dll", SetLastError=true)]
    static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    static void SendVK(ushort vk) {
        INPUT[] inputs = new INPUT[2];
        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].U.ki = new KEYBDINPUT { wVk = vk, wScan = 0, dwFlags = 0, time = 0, dwExtraInfo = IntPtr.Zero };

        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].U.ki = new KEYBDINPUT { wVk = vk, wScan = 0, dwFlags = KEYEVENTF_KEYUP, time = 0, dwExtraInfo = IntPtr.Zero };

        SendInput(2, inputs, Marshal.SizeOf(typeof(INPUT)));
    }

    static void SendUnicodeChar(char c) {
        ushort scan = c; // UTF-16 code unit
        INPUT[] inputs = new INPUT[2];

        inputs[0].type = INPUT_KEYBOARD;
        inputs[0].U.ki = new KEYBDINPUT { wVk = 0, wScan = scan, dwFlags = KEYEVENTF_UNICODE, time = 0, dwExtraInfo = IntPtr.Zero };

        inputs[1].type = INPUT_KEYBOARD;
        inputs[1].U.ki = new KEYBDINPUT { wVk = 0, wScan = scan, dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP, time = 0, dwExtraInfo = IntPtr.Zero };

        SendInput(2, inputs, Marshal.SizeOf(typeof(INPUT)));
    }

    public static void TypeText(string text, int charDelayMs, string newlineMode) {
        if (text == null) return;

        foreach (char c in text) {
            if (c == '\n') {
                if (newlineMode == "Enter") SendVK(VK_RETURN);
                else if (newlineMode == "Space") SendUnicodeChar(' ');
                else { /* Ignore */ }
            }
            else if (c == '\t') {
                // 탭은 포커스 이동 가능성이 있어 그대로 TAB 키로 처리
                SendVK(VK_TAB);
            }
            else {
                SendUnicodeChar(c);
            }

            if (charDelayMs > 0) Thread.Sleep(charDelayMs);
        }
    }
}
"@ | Out-Null

Write-Host ""
Write-Host "클립보드 문자 수: $($text.Length)"
Write-Host "사용법: 텍스트를 Ctrl+C로 복사한 뒤, 이 파일을 우클릭해 'PowerShell에서 실행'을 누르세요."
Write-Host "입력 시작까지 $StartDelaySec 초. 지금부터 $StartDelaySec 초 안에 입력칸에 커서를 두세요."

for ($i = $StartDelaySec; $i -ge 1; $i--) {
    Write-Host "  $i..."
    Start-Sleep -Seconds 1
}

Write-Host "입력 시작."
[Typer]::TypeText($text, $CharDelayMs, $NewlineMode)
Write-Host "완료."
