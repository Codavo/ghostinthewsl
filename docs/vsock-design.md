# Phase 6: vsock Direct Communication

## Overview

Replace `wsl.exe` stdio relay with direct `AF_VSOCK` / `AF_HYPERV` socket
communication between the Windows host and the WSL2 VM. This eliminates the
wsl.exe middleman, reduces latency, and enables a singleton bridge daemon
managing multiple PTYs.

## Why vsock?

| | Current (wsl.exe relay) | vsock |
|---|---|---|
| Latency | ~2ms per-byte (two process hops) | ~0.1ms (kernel-to-kernel) |
| Processes per tab | 2 (wsl.exe + bridge) | 1 shared daemon |
| Startup time | ~500ms (wsl.exe launch) | ~10ms (connect) |
| Bridge deploy | Every session (via wsl.exe pipe) | Once (daemon auto-updates) |
| Max throughput | Limited by pipe buffering | ~1GB/s (hypervisor bus) |

## Architecture

```
Windows (Ghostty)              WSL2 VM
┌──────────────┐         ┌──────────────────┐
│  Surface 1   │◄──vsock──►  PTY 1 (bash)   │
│  Surface 2   │◄──vsock──►  PTY 2 (zsh)    │
│  Surface 3   │◄──vsock──►  PTY 3 (vim)    │
│              │         │                  │
│  Ghostty.exe │         │  wsl-pty-daemon  │
└──────────────┘         └──────────────────┘
     AF_HYPERV                 AF_VSOCK
```

Each tab gets its own vsock connection to the daemon. The daemon manages one
PTY per connection. When a connection drops, the daemon cleans up that PTY.

## Socket Addressing

### Windows side: AF_HYPERV
```c
struct sockaddr_hv {
    unsigned short Family;      // AF_HYPERV (34)
    unsigned short Reserved;
    GUID VmId;                  // Target VM GUID
    GUID ServiceId;             // Application-defined GUID
};
```

- **VmId**: The WSL2 VM's GUID. Obtained via `wslinfo --vm-id` (WSL 2.4.4+)
  or from registry `HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss\{distro-guid}\VmId`.
- **ServiceId**: A fixed GUID we define for GhostInTheWSL, e.g.
  `{a1b2c3d4-e5f6-7890-abcd-ef1234567890}`. Must be registered in the VM's
  `/etc/wsl-vpn.conf` or the Hyper-V firewall.

### Linux side: AF_VSOCK
```c
struct sockaddr_vm {
    sa_family_t svm_family;     // AF_VSOCK (40)
    unsigned short svm_reserved1;
    unsigned int svm_port;      // Port number (our chosen port)
    unsigned int svm_cid;       // VMADDR_CID_ANY (for listen)
};
```

- **svm_cid**: `VMADDR_CID_ANY` (-1U) for listening, `VMADDR_CID_HOST` (2) for connecting to the host.
- **svm_port**: A fixed port number, e.g. `6847` ("GIWL").

## VM ID Discovery

The hardest part. Three approaches in priority order:

### 1. `wslinfo --vm-id` (preferred)
Available since WSL 2.4.4 (late 2024). Run inside WSL:
```
$ wslinfo --vm-id
xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```
From Windows, run `wsl.exe -d <distro> -- wslinfo --vm-id` during initialization.

### 2. HCS (Host Compute Service) API
```c
HcsEnumerateComputeSystems(query, &result, &operation);
// Parse JSON result for WSL VM GUIDs
```
Requires linking `computecore.dll`. More complex but doesn't need wsl.exe.

### 3. Registry lookup
```
HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss\{distro-guid}
```
The `VmId` value may not exist on all WSL versions. Least reliable.

## Connection Protocol

### Handshake (after vsock connect)

```
Client (Ghostty) → Server (daemon):
  GHOSTWSL\x01                    # magic + version
  <cols:u16><rows:u16>            # initial terminal size
  <xpixel:u16><ypixel:u16>       # pixel dimensions
  <shell_len:u16><shell:utf8>    # shell path (0 = default)
  <cwd_len:u16><cwd:utf8>        # working directory (0 = default)

Server → Client:
  OK\x01                          # success + version
  <pty_id:u32>                    # PTY identifier (for logging)
```

### Data Phase

After handshake, the connection is a raw bidirectional byte stream:

- **Client → Server**: Keyboard input + APC control commands (same format as current)
  - `\x1b_Gwsl;resize;COLS;ROWS;XPIXEL;YPIXEL\x1b\\`
  - `\x1b_Gwsl;signal;SIGNUM\x1b\\`
- **Server → Client**: PTY output (zero filtering, preserves kitty graphics)

The APC in-band protocol is reused as-is. This means the bridge's APC parser
and the Zig-side APC formatting code stay unchanged.

### Disconnect

When the vsock connection closes:
1. Daemon sends SIGHUP to the PTY's child process group
2. Waits up to 2 seconds for graceful exit
3. Escalates to SIGKILL if needed
4. Cleans up PTY file descriptors

Same logic as current `wait_for_child()` in bridge.rs.

## Implementation Plan

### Daemon (Rust, ~250 lines new code)

Modify `wsl-pty-bridge` to support two modes:

```
wsl-pty-bridge --shell /bin/zsh --cols 80 --rows 24   # current: stdio mode
wsl-pty-bridge --daemon --port 6847                     # new: vsock daemon mode
```

New modules:
- `daemon.rs`: vsock listener, accept loop, per-connection spawn
- `vsock.rs`: AF_VSOCK socket setup, handshake parsing

The daemon's per-connection handler reuses `bridge::run()` but with the vsock
fd instead of stdin/stdout.

```rust
// Pseudocode for daemon accept loop
fn daemon_main(port: u32) {
    let listener = VsockListener::bind(VMADDR_CID_ANY, port)?;
    loop {
        let (stream, _addr) = listener.accept()?;
        std::thread::spawn(move || {
            let config = read_handshake(&stream)?;
            let child = PtyChild::spawn(&config.shell, config.cols, config.rows, config.cwd)?;
            // Redirect stream fd as stdin/stdout equivalent
            bridge::run_with_fd(&child, stream.as_raw_fd())?;
        });
    }
}
```

### Zig Side (~150 lines new code)

New file: `src/apprt/win32/VsockBridge.zig`

```zig
const VsockBridge = @This();

/// AF_HYPERV socket handle
socket: windows.HANDLE,
/// Current terminal size
size: ptypkg.winsize,

pub fn open(config: Config) !VsockBridge {
    // 1. Discover VM ID via wsl.exe -e wslinfo --vm-id
    // 2. Create AF_HYPERV socket
    // 3. Connect to daemon
    // 4. Send handshake
    // 5. Read OK response
    // Return socket handle (usable with xev/IOCP via WSARecv/WSASend)
}
```

The socket handle replaces the pipe handles. Since Winsock2 sockets support
overlapped I/O natively, xev/IOCP integration should be straightforward.

### Exec.zig Changes

```zig
// In startWslBridge():
if (try VsockBridge.tryConnect(config)) |vsock| {
    // vsock daemon available — use direct connection
    self.vsock_bridge = vsock;
} else {
    // Fall back to wsl.exe stdio relay
    self.wsl_bridge = try WslBridge.open(config);
}
```

### Daemon Lifecycle

1. **Auto-start**: On first tab open, if vsock connect fails, start the daemon:
   ```
   wsl.exe -d <distro> -- wsl-pty-bridge --daemon --port 6847 &
   ```
   Then retry the vsock connect.

2. **Auto-stop**: Daemon exits when it has zero active PTYs and has been idle
   for 30 seconds. This prevents orphaned daemons.

3. **Health check**: Periodic vsock ping or rely on connection-level keepalive.

## Hyper-V Firewall / vsock Registration

WSL2 vsock requires the service GUID to be registered. Two approaches:

### 1. hvsocket registry key (requires admin, one-time)
```
HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization\GuestCommunicationServices\{service-guid}
  ElementName = "GhostInTheWSL"
```

### 2. WSL 2.0+ built-in vsock support
Modern WSL versions allow vsock without explicit registration for ports in
certain ranges. Need to verify exact behavior on target WSL versions.

## Fallback Strategy

The wsl.exe stdio relay remains as a fallback:
1. vsock not available (old WSL version, no Hyper-V)
2. VM ID discovery fails
3. Daemon not running and can't be started
4. Firewall blocks vsock

The Zig code tries vsock first, falls back to WslBridge.open() on any error.

## Testing

- Unit tests: Handshake encode/decode, VM ID parsing
- Integration: Start daemon in WSL, connect from Windows, verify PTY I/O
- Stress: Multiple simultaneous connections, rapid connect/disconnect
- Fallback: Verify graceful degradation when vsock unavailable

## Estimated Effort

- Daemon mode in Rust: ~200 lines, 1 session
- VsockBridge.zig: ~150 lines, 1 session
- VM ID discovery + registration: ~50 lines + testing, half session
- Integration + testing: 1 session
- **Total: ~3-4 sessions**
