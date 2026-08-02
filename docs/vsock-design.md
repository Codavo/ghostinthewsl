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
│ Control mgr  │──vsock──► Session registry │
│  Ghostty.exe │         │  wsl-pty-daemon  │
└──────────────┘         └──────────────────┘
     AF_HYPERV                 AF_VSOCK
```

Each tab gets a data connection carrying only raw PTY bytes. A single shared
control connection per distro multiplexes resize and signal commands for all
tabs. The daemon assigns an unpredictable 128-bit session capability during
the data handshake and removes it when that data connection closes.

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
- **svm_port**: Port `48470` for the default distro; named distros use a
  deterministic port in the `48471`-`49470` range.

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
Client (Ghostty) → Server (daemon), data role:
  GWSL\x03                        # magic + version
  1                               # connection role
  <token:32 bytes>                # per-daemon authentication
  <cols:u16><rows:u16>            # initial terminal size
  <xpixel:u16><ypixel:u16>        # pixel dimensions
  <shell_len:u16><shell:utf8>     # shell path (0 = default)
  <cwd_len:u16><cwd:utf8>         # working directory (0 = default)

Server → Client:
  OK\x02                          # success + response version
  <pty_id:u32>                    # PTY identifier (for logging)
  <session_id:16 bytes>           # capability for control commands
```

### Data Phase

After the data handshake, the connection is an unmodified bidirectional byte
stream. Every byte from the terminal, including standalone ESC and APC/OSC
sequences, reaches the PTY without protocol interpretation.

### Control Connection

The process-wide control manager connects lazily when a resize is queued:

```
Client → Server:
  GWSL\x03 + 2 + <token:32 bytes>

Server → Client:
  OKC\x01

Client → Server, repeated frames:
  <type:u8><payload_len:u16><payload>

Resize payload (type 1, 32 bytes):
  <session_id:16><serial:u64><cols:u16><rows:u16><xpixel:u16><ypixel:u16>

Signal payload (type 2, 20 bytes):
  <session_id:16><signum:i32>
```

Resize messages carry monotonic per-session serials. Both sides coalesce
pending resize messages, and the daemon rejects stale serials. The control
writer is isolated on a background thread, so connection or daemon stalls
cannot block terminal input. Exact ordering between data and control sockets
is not guaranteed; the bridge applies controls before data when both are ready.
This is intentionally relaxed because merely changing poll priority cannot
provide real cross-socket ordering.

If strict ordering becomes necessary, resize frames can carry an input-byte
barrier: "apply after N data bytes." The Windows IO thread would snapshot its
cumulative sent-byte count when queuing a resize, while the daemon would track
bytes delivered to the PTY and split socket reads at pending barriers. This
preserves the raw data stream and shared control connection, but adds protocol
and bridge-loop state that is not justified without an observed ordering bug.

### Disconnect

When the vsock connection closes:
1. Daemon sends SIGHUP to the PTY's child process group
2. Waits up to 2 seconds for graceful exit
3. Escalates to SIGKILL if needed
4. Cleans up PTY file descriptors

Same logic as current `wait_for_child()` in bridge.rs.

## Current Implementation

### Daemon (Rust, ~250 lines new code)

`wsl-pty-bridge` supports two modes:

```
wsl-pty-bridge --shell /bin/zsh --cols 80 --rows 24   # stdio mode
wsl-pty-bridge --daemon --port 48470                  # vsock daemon mode
```

- `daemon.rs`: vsock listener, accept loop, per-connection spawn
- `control.rs`: bounded per-session queues and pollable wake descriptors
- `bridge.rs`: raw PTY proxy and control dispatch

The daemon's data handler reuses the bridge event loop with the vsock fd and a
pollable per-session control queue. Control reader threads never access PTYs
directly.

### Zig Side (~150 lines new code)

`src/apprt/win32/VsockBridge.zig` manages deployment, authentication, data
handshakes, and one background control writer per distro. Data uses blocking
Winsock `recv()` on the reader thread and `send()` on the IO thread; this avoids
the unreliable IOCP/overlapped path for AF_HYPERV sockets.

### Exec.zig Changes

`Exec.zig` stores the session capability returned by the data handshake and
queues resize messages without touching the data socket.

### Daemon Lifecycle

1. **Auto-start**: On first tab open, if vsock connect fails, start the daemon:
   ```
   wsl.exe -d <distro> -- wsl-pty-bridge --daemon --port 48470
   ```
   Then retry the vsock connect.

2. **Lifetime**: The app currently starts the daemon with `--idle-timeout 0`,
   so it persists until replaced, explicitly killed, or WSL shuts down.

3. **Reconnect**: The control writer reconnects lazily after socket failures.

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

## Testing

- Unit tests: Handshake encode/decode, VM ID parsing
- Integration: Start daemon in WSL, connect from Windows, verify PTY I/O
- Stress: Multiple simultaneous connections, rapid connect/disconnect
- Recovery: Restart the daemon and verify that the control manager reconnects
