# GhostInTheWSL

<p align="center">
    <img src="images/ghostinthewsl-logo2.png" alt="GhostInTheWSL logo" width="192">
</p>

GhostInTheWSL is a Windows version of the [Ghostty](https://ghostty.org/docs) terminal emulator designed for use with WSL. The goal is a seamless modern terminal experience for WSL. It is available as a portable .exe or can be installed if desired.

Downloads: [GitHub Releases](https://github.com/Codavo/ghostinthewsl/releases)

It avoids the Windows terminal infrastructure and only connects directly to the WSL 2 Linux VM.

It supports fancy terminal features such as kitty graphics and doesn't suffer from the issues introduced by [ConPTY](https://devblogs.microsoft.com/commandline/windows-command-line-introducing-the-windows-pseudo-console-conpty/) thanks to bypassing it entirely.

It runs the terminal UI on Windows, starts a real Linux PTY inside WSL via a small bridge application running inside the WSL guest, and talks to it over Hyper-V sockets on Windows and VSOCK inside WSL instead of going through ConPTY.

As of this writing Ghostty doesn't yet natively support Windows so the Windows support is based on [this](https://github.com/mattn/ghostty/tree/win32-apprt) ghostty fork by [mattn](https://github.com/mattn). Once proper Windows support is available upstream the project should be switched over.

GhostInTheWSL also adds improved tab controls and provides a simple keepalive for WSL since otherwise [vmIdleTimeout](https://learn.microsoft.com/en-us/windows/wsl/wsl-config) can shutdown the WSL 2 VM because the Hyper-V socket connection doesn't count towards making the VM not idle. The Ghostty terminfo entry is also installed automatically in the WSL distro.

For the Ghostty config file, GhostInTheWSL first looks for `config.ghostinthewsl` next to the executable, then for `%APPDATA%\\ghostinthewsl\\config`, then `%APPDATA%\\ghostinthewsl\\config.ghostinthewsl`. Later files override earlier ones if present.

Note: WSL 1 is not supported.
