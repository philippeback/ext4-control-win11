#Requires -Version 5.1
<#
.SYNOPSIS
    Interactive menu to mount, drive-letter map, and unmount Synology ext4 USB drives on Windows 11 via WSL 2.
.DESCRIPTION
    Works natively in Windows PowerShell 5.1. Runs in the user's desktop session so
    subst drive-letter mappings (default S:) are visible in File Explorer, and elevates
    only the wsl --mount / --unmount calls via UAC.
#>

param(
    [string]$DriveLetter = "S",
    [string]$Distro = "",          # Leave empty to use default WSL 2 distro
    [int]$Partition = 1,
    [string]$FileSystem = "ext4"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function Reset-ConsoleMode {
    # wsl.exe / fzf.exe can leave DISABLE_NEWLINE_AUTO_RETURN (0x0008) set on ConPTY stdout,
    # causing Write-Host lines to stair-step across the terminal.
    if (-not ("Win32.ConsoleHelper" -as [type])) {
        Add-Type -Namespace Win32 -Name ConsoleHelper -MemberDefinition @"
            [DllImport("kernel32.dll", SetLastError = true)]
            public static extern IntPtr GetStdHandle(int nStdHandle);
            [DllImport("kernel32.dll", SetLastError = true)]
            public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
            [DllImport("kernel32.dll", SetLastError = true)]
            public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
"@
    }
    $handle = [Win32.ConsoleHelper]::GetStdHandle(-11) # STD_OUTPUT_HANDLE
    $mode = [uint32]0
    if ([Win32.ConsoleHelper]::GetConsoleMode($handle, [ref]$mode)) {
        $fixed = ($mode -band (-bnot 0x0008)) -bor 0x0003
        [void][Win32.ConsoleHelper]::SetConsoleMode($handle, $fixed)
    }
}

# --- 1. Elevation Helpers (Only wsl --mount / --unmount require Administrator) ---
# Running the main script non-elevated ensures subst drive letters are visible in File Explorer.
function Test-IsAdministrator {
    $currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-ElevatedWsl {
    param([string[]]$Arguments)
    if (Test-IsAdministrator) {
        & wsl.exe @Arguments
        return $LASTEXITCODE
    }
    $proc = Start-Process -FilePath "wsl.exe" -ArgumentList $Arguments -Verb RunAs -Wait -PassThru
    return $proc.ExitCode
}

# --- 2. Resolve WSL Distro Name ---
function Get-TargetWslDistro {
    param([string]$Preferred)
    if ($Preferred) { return $Preferred }
    # Parse wsl -l -q (strips UTF-16 null bytes emitted by wsl.exe in PS 5.1)
    $raw = & wsl.exe -l -q 2>$null
    $distros = $raw | ForEach-Object { ($_ -replace "`0", "").Trim() } | Where-Object { $_ -ne "" }
    if (-not $distros) {
        throw "No WSL 2 distribution found. Install one first (e.g., 'wsl --install -d Ubuntu --no-launch')."
    }
    if ($distros -is [array]) { return $distros[0] }
    return $distros
}

# --- 3. Enumerate USB Physical Drives ---
function Get-UsbPhysicalDrives {
    # Get-Disk cleanly exposes BusType = 'USB' on Windows 11
    $usbDisks = Get-Disk | Where-Object { $_.BusType -eq "USB" }
    $results = @()
    foreach ($d in $usbDisks) {
        $sizeGB = [math]::Round($d.Size / 1GB, 2)
        $results += [PSCustomObject]@{
            Number       = $d.Number
            DeviceID     = "\\.\PHYSICALDRIVE$($d.Number)"
            FriendlyName = $d.FriendlyName
            SizeGB       = $sizeGB
            Status       = $d.OperationalStatus
            Label        = "Disk $($d.Number) | $($d.FriendlyName) | ${sizeGB} GB | $($d.OperationalStatus)"
        }
    }
    return $results
}

# --- 4. Interactive Selector (Uses Scoop fzf if available, else native PS 5 menu) ---
function Select-MenuItem {
    param(
        [string]$Title,
        [array]$Items,
        [string]$DisplayProperty = "Label"
    )
    if (-not $Items -or $Items.Count -eq 0) { return $null }

    $fzfCmd = Get-Command fzf.exe -ErrorAction SilentlyContinue
    if ($fzfCmd) {
        $lines = for ($i = 0; $i -lt $Items.Count; $i++) {
            "$i`t$($Items[$i].$DisplayProperty)"
        }
        $selected = $lines | & $fzfCmd.Source --height=40% --reverse --border --with-nth=2.. --prompt="$Title > "
        if (-not $selected) { return $null }
        $idx = [int]($selected -split "`t")[0]
        return $Items[$idx]
    }

    Write-Host "`n=== $Title ===" -ForegroundColor Cyan
    for ($i = 0; $i -lt $Items.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $Items[$i].$DisplayProperty)
    }
    Write-Host "  [0] Cancel / Back" -ForegroundColor DarkGray
    $choice = Read-Host "Select number"
    if ($choice -match '^\d+$') {
        $num = [int]$choice
        if ($num -ge 1 -and $num -le $Items.Count) {
            return $Items[$num - 1]
        }
    }
    return $null
}

# --- 5. Drive Letter Mapping Helpers ---
function Map-WslShareToLetter {
    param(
        [string]$Letter,
        [string]$UncPath
    )
    $cleanLetter = $Letter.TrimEnd(":")
    $driveRoot = "${cleanLetter}:"

    # Remove stale mapping on the same letter if present
    if (Test-Path $driveRoot) {
        & cmd.exe /c "subst $driveRoot /D >nul 2>&1 & net use $driveRoot /delete /y >nul 2>&1"
    }

    # Wait briefly for \\wsl.localhost mountpoint to materialize
    $retries = 10
    while (-not (Test-Path $UncPath) -and $retries -gt 0) {
        Start-Sleep -Milliseconds 500
        $retries--
    }

    if (-not (Test-Path $UncPath)) {
        Write-Warning "WSL mounted the disk, but UNC path '$UncPath' was not immediately visible."
        return $false
    }

    # subst maps a local drive letter directly to \\wsl.localhost\... without SMB auth prompts
    & subst.exe $driveRoot $UncPath
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Mapped $driveRoot -> $UncPath" -ForegroundColor Green
        if (Test-IsAdministrator) {
            Write-Host "Note: Running elevated; if $driveRoot is not visible in File Explorer, run this script from a non-elevated PowerShell." -ForegroundColor DarkYellow
        }
        return $true
    } else {
        Write-Warning "subst failed for $driveRoot. You can still browse directly at: $UncPath"
        return $false
    }
}

function Unmap-DriveLetter {
    param([string]$Letter)
    $cleanLetter = $Letter.TrimEnd(":")
    $driveRoot = "${cleanLetter}:"
    if (Test-Path $driveRoot) {
        & cmd.exe /c "subst $driveRoot /D >nul 2>&1 & net use $driveRoot /delete /y >nul 2>&1"
        Write-Host "Unmapped drive letter $driveRoot" -ForegroundColor Yellow
    }
}

function Get-WslIdmapMount {
    param(
        [string]$TargetDistro,
        [string]$MountName
    )
    $rawPath = "/mnt/wsl/$MountName"
    $winMountName = "${MountName}_win"
    $winPath = "/mnt/wsl/$winMountName"

    $uid = ((& wsl.exe -d $TargetDistro -- id -u 2>$null) | Out-String).Trim()
    $gid = ((& wsl.exe -d $TargetDistro -- id -g 2>$null) | Out-String).Trim()
    if (-not ($uid -match '^\d+$') -or -not ($gid -match '^\d+$')) {
        return $MountName
    }

    # Detect non-root owner UIDs in the top-level directory (e.g. Synology DSM UID 1026)
    $srcUid = ((& wsl.exe -d $TargetDistro -u root -- bash -c "stat -c '%u' '$rawPath'/* 2>/dev/null | grep -E '^[0-9]{4,}$' | grep -vx '$uid' | head -n 1" 2>$null) | Out-String).Trim()
    if (-not ($srcUid -match '^\d+$')) {
        $srcUid = "1026"
    }

    $idmapSpec = "u:0:0:1 u:${srcUid}:${uid}:1 g:100:${gid}:1"
    $cmd = "mkdir -p '$winPath'; if mountpoint -q '$winPath'; then exit 0; fi; umount -l '$winPath' 2>/dev/null || true; mount --bind -o 'X-mount.idmap=$idmapSpec' '$rawPath' '$winPath'"
    & wsl.exe -d $TargetDistro -u root -- bash -c $cmd 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Mounted kernel idmap view (${srcUid}->${uid}) at $winPath" -ForegroundColor Green
        return $winMountName
    }

    Write-Warning "Kernel idmap mount failed; falling back to raw mount $rawPath."
    return $MountName
}

function Remove-WslIdmapMount {
    param(
        [string]$TargetDistro,
        [string]$MountName
    )
    $winPath = "/mnt/wsl/${MountName}_win"
    & wsl.exe -d $TargetDistro -u root -- bash -c "umount -l '$winPath' 2>/dev/null || true; rmdir '$winPath' 2>/dev/null || true" 2>$null | Out-Null
}

# --- 6. Core Actions ---
function Invoke-MountAndMap {
    param([string]$TargetDistro, [string]$Letter)
    $drives = Get-UsbPhysicalDrives
    if (-not $drives) {
        Write-Warning "No USB physical drives detected."
        return
    }

    $picked = Select-MenuItem -Title "Select USB Drive to Mount ($FileSystem)" -Items $drives
    if (-not $picked) { return }

    $mountName = "PHYSICALDRIVE$($picked.Number)p$Partition"
    $rawUncPath = "\\wsl.localhost\$TargetDistro\mnt\wsl\$mountName"

    # Wake WSL distro VM first to check if already mounted
    & wsl.exe -d $TargetDistro -- true 2>$null | Out-Null
    if (Test-Path $rawUncPath) {
        Write-Host "$mountName is already mounted in WSL at $rawUncPath. Mapping drive letter..." -ForegroundColor Yellow
    } else {
        Write-Host "Mounting $($picked.DeviceID) (partition $Partition, $FileSystem) into WSL (UAC prompt if not elevated)..." -ForegroundColor Cyan
        $mountExit = Invoke-ElevatedWsl -Arguments @("--mount", $picked.DeviceID, "--partition", "$Partition", "--type", $FileSystem)
        if ($mountExit -ne 0) {
            Write-Error "wsl --mount failed (exit code $mountExit). Check if already mounted or partition index differs."
            return
        }

        # Ensure WSL distro VM is awake so \\wsl.localhost responds
        & wsl.exe -d $TargetDistro -- true 2>$null | Out-Null
    }

    $effectiveMount = Get-WslIdmapMount -TargetDistro $TargetDistro -MountName $mountName
    $uncPath = "\\wsl.localhost\$TargetDistro\mnt\wsl\$effectiveMount"
    Map-WslShareToLetter -Letter $Letter -UncPath $uncPath | Out-Null
}

function Invoke-UnmapAndUnmount {
    param([string]$TargetDistro, [string]$Letter)
    $drives = Get-UsbPhysicalDrives
    if (-not $drives) {
        Write-Warning "No USB physical drives detected."
        return
    }

    $picked = Select-MenuItem -Title "Select USB Drive to Unmount Safely" -Items $drives
    if (-not $picked) { return }

    Unmap-DriveLetter -Letter $Letter

    $mountName = "PHYSICALDRIVE$($picked.Number)p$Partition"
    Remove-WslIdmapMount -TargetDistro $TargetDistro -MountName $mountName

    Write-Host "Syncing buffers and unmounting $($picked.DeviceID) from WSL (UAC prompt if not elevated)..." -ForegroundColor Cyan
    & wsl.exe -d $TargetDistro -- sync 2>$null | Out-Null
    $unmountExit = Invoke-ElevatedWsl -Arguments @("--unmount", $picked.DeviceID)
    if ($unmountExit -eq 0) {
        Write-Host "Safe to unplug $($picked.FriendlyName) ($($picked.DeviceID))." -ForegroundColor Green
    } else {
        Write-Warning "wsl --unmount returned code $unmountExit (drive may already be unmounted)."
    }
}

function Show-Status {
    param([string]$TargetDistro, [string]$Letter)
    Write-Host "`n--- Active USB Physical Disks ---" -ForegroundColor Cyan
    $drives = Get-UsbPhysicalDrives
    if ($drives) {
        $drives | Format-Table Number, DeviceID, FriendlyName, SizeGB, Status -AutoSize
    } else {
        Write-Host "No USB disks attached." -ForegroundColor DarkGray
    }

    Write-Host "--- Active WSL Mounts (/mnt/wsl) ---" -ForegroundColor Cyan
    & wsl.exe -d $TargetDistro -- ls -la /mnt/wsl 2>$null
    Reset-ConsoleMode

    $driveRoot = "$($Letter.TrimEnd(':')):"
    Write-Host "`n--- Drive Letter $driveRoot Status ---" -ForegroundColor Cyan
    if (Test-Path $driveRoot) {
        Write-Host "$driveRoot is currently mapped and accessible." -ForegroundColor Green
    } else {
        Write-Host "$driveRoot is not mapped." -ForegroundColor DarkGray
    }
}

# --- 7. Main Menu Loop ---
try {
    $targetDistro = Get-TargetWslDistro -Preferred $Distro
} catch {
    Write-Error $_
    Read-Host "Press Enter to exit"
    exit 1
}

while ($true) {
    Reset-ConsoleMode
    Write-Host "`n==========================================" -ForegroundColor DarkCyan
    Write-Host " Synology EXT4 USB Manager (WSL2 -> $($DriveLetter.TrimEnd(':')):)" -ForegroundColor White
    Write-Host " Distro: $targetDistro" -ForegroundColor DarkGray
    Write-Host "==========================================" -ForegroundColor DarkCyan
    Write-Host "  [1] Mount USB drive & map to $($DriveLetter.TrimEnd(':')):"
    Write-Host "  [2] Unmap $($DriveLetter.TrimEnd(':')): & safely unmount USB drive"
    Write-Host "  [3] Show USB disks & WSL mount status"
    Write-Host "  [4] Open $($DriveLetter.TrimEnd(':')): in File Explorer"
    Write-Host "  [Q] Quit"

    $op = Read-Host "`nChoice"
    switch ($op.ToUpper()) {
        "1" { Invoke-MountAndMap -TargetDistro $targetDistro -Letter $DriveLetter }
        "2" { Invoke-UnmapAndUnmount -TargetDistro $targetDistro -Letter $DriveLetter }
        "3" { Show-Status -TargetDistro $targetDistro -Letter $DriveLetter }
        "4" {
            $root = "$($DriveLetter.TrimEnd(':')):\"
            if (Test-Path $root) { Start-Process explorer.exe $root }
            else { Write-Warning "$root is not mapped yet." }
        }
        "Q" { break }
        default { Write-Host "Invalid option." -ForegroundColor DarkGray }
    }
    if ($op.ToUpper() -eq "Q") { break }
}