# Control-Disks.ps1

Interactive PowerShell menu to mount, map to a Windows drive letter, and safely unmount `ext4` USB drives (such as Synology external backup drives) on Windows 11 using WSL 2.

## Features

- **Targeted Administrator elevation** — Runs in your normal desktop session (so `subst` drive letters are visible in File Explorer) and elevates only `wsl --mount` and `wsl --unmount` via UAC.
- **Non-destructive Synology UID mapping (`X-mount.idmap`)** — Automatically creates a kernel-level idmapped bind mount (`<mountName>_win`) so Synology-owned folders (e.g., `UID 1026`) are accessible in Windows without modifying permissions on the disk or relying on a FUSE daemon.
- **USB physical disk discovery** — Detects attached USB drives (`BusType = USB`) and displays disk number, model, size (GB), and operational status.
- **Interactive selector** — Uses `fzf.exe` if available on `PATH` (e.g., via Scoop), and automatically falls back to a native numbered PowerShell menu.
- **Drive-letter mapping** — Maps `\\wsl.localhost\<Distro>\mnt\wsl\PHYSICALDRIVE<N>p<Partition>` to a local Windows drive letter (default `S:`) using `subst.exe` without SMB authentication prompts.
- **Safe unmount** — Unmaps the drive letter, flushes filesystem buffers with `sync` inside WSL, and detaches the physical disk via `wsl --unmount`.

## Prerequisites

- **Windows 11** (or Windows with WSL 2 raw disk passthrough support)
- **Windows PowerShell 5.1** (`#Requires -Version 5.1`)
- **WSL 2** with at least one installed Linux distribution (for example: `wsl --install -d Ubuntu --no-launch`)
- **Optional:** [`fzf`](https://github.com/junegunn/fzf) (`fzf.exe`) for fuzzy-search selection menus

## Usage

Run the script from PowerShell:

```powershell
.\Control-Disks.ps1
```

If script execution is restricted by your PowerShell execution policy:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Control-Disks.ps1
```

### Parameters

| Parameter | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `-DriveLetter` | `string` | `"S"` | Windows drive letter to map the mounted disk to (with or without `:`). |
| `-Distro` | `string` | `""` | WSL 2 distribution name. When empty, uses the first distribution returned by `wsl -l -q`. |
| `-Partition` | `int` | `1` | Partition index on the USB drive to mount. |
| `-FileSystem` | `string` | `"ext4"` | Filesystem type passed to `wsl --mount --type`. |

### Examples

Mount partition `1` (`ext4`) to `S:` using the default WSL 2 distro:

```powershell
.\Control-Disks.ps1
```

Mount partition `2` to `X:` using a specific WSL 2 distro:

```powershell
.\Control-Disks.ps1 -DriveLetter X -Distro Ubuntu -Partition 2
```

## Interactive Menu

Once running, the script presents the following options:

1. **`[1] Mount USB drive & map to <DriveLetter>:`**  
   Select an attached USB disk, mount the configured partition into WSL 2, wake the target distro, and map the resulting `\\wsl.localhost` path to `<DriveLetter>:`.
2. **`[2] Unmap <DriveLetter>: & safely unmount USB drive`**  
   Remove the `<DriveLetter>:` mapping (`subst /D` / `net use /delete`), run `sync` inside WSL, and detach the physical disk with `wsl --unmount`.
3. **`[3] Show USB disks & WSL mount status`**  
   Display attached USB physical disks, active mounts under `/mnt/wsl`, and whether `<DriveLetter>:` is currently mapped.
4. **`[4] Open <DriveLetter>: in File Explorer`**  
   Launch `explorer.exe` at `<DriveLetter>:\` if the drive is mapped.
5. **`[Q] Quit`**  
   Exit the script.

## Notes & Troubleshooting

- **Always unmount before unplugging:** Use option `[2]` to flush buffers and detach the drive from WSL before disconnecting the USB cable.
- **Wrong partition or filesystem:** If `wsl --mount` fails, verify the partition number or filesystem type and pass `-Partition` / `-FileSystem` accordingly.
- **Mapping fallback:** If `subst.exe` fails or the UNC path is slow to appear, you can still access the mounted volume directly in File Explorer at:
  `\\wsl.localhost\<Distro>\mnt\wsl\PHYSICALDRIVE<N>p<Partition>`
- **No WSL distro found:** Install a WSL 2 distribution first (e.g., `wsl --install -d Ubuntu --no-launch`).
