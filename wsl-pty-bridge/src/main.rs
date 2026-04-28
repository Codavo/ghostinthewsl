mod bridge;
mod daemon;
mod protocol;
mod pty;

use clap::Parser;

/// WSL PTY Bridge for GhostInTheWSL.
///
/// Creates a real Linux PTY inside WSL, proxying I/O between stdin/stdout
/// and the PTY master. Designed to be launched by the Windows host via:
///   wsl.exe -e wsl-pty-bridge --shell /bin/zsh
///
/// This bypasses ConPTY entirely, preserving all escape sequences including
/// the kitty graphics protocol.
#[derive(Parser, Debug)]
#[command(name = "wsl-pty-bridge", version, about)]
struct Args {
    /// Path to the shell to launch.
    /// Defaults to $SHELL, then /bin/sh.
    #[arg(long, default_value_t = default_shell())]
    shell: String,

    /// Initial number of columns.
    #[arg(long, default_value_t = 80)]
    cols: u16,

    /// Initial number of rows.
    #[arg(long, default_value_t = 24)]
    rows: u16,

    /// Initial working directory.
    /// Defaults to the user's home directory.
    #[arg(long)]
    cwd: Option<String>,

    /// Run as a daemon listening on vsock for multiple connections.
    #[arg(long)]
    daemon: bool,

    /// vsock port to listen on in daemon mode.
    #[arg(long, default_value_t = 48470)]
    port: u32,

    /// Idle timeout in seconds for daemon mode. 0 = no timeout (run forever).
    #[arg(long, default_value_t = 0)]
    idle_timeout: u64,
}

fn default_shell() -> String {
    std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string())
}

fn main() {
    let args = Args::parse();

    // Initialize logging. stderr goes to NUL on the Windows side, so
    // use file-based logging when GHOSTWSL_LOG=1 is set for debugging.
    // Daemon mode always logs to help diagnose connection issues.
    let want_log = args.daemon || std::env::var("GHOSTWSL_LOG").is_ok();
    if want_log {
        let log_path = if args.daemon {
            "/tmp/wsl-pty-bridge-daemon.log"
        } else {
            "/tmp/wsl-pty-bridge.log"
        };
        if let Ok(file) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(log_path)
        {
            env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("debug"))
                .format_timestamp_millis()
                .target(env_logger::Target::Pipe(Box::new(file)))
                .init();
        }
    } else {
        // No-op logger — log macros compile to nothing at runtime.
        log::set_max_level(log::LevelFilter::Off);
    }

    // Daemon mode: listen on vsock and handle multiple connections.
    if args.daemon {
        log::info!("Starting wsl-pty-bridge daemon on vsock port {}", args.port);
        match daemon::run(args.port, args.idle_timeout) {
            Ok(()) => std::process::exit(0),
            Err(e) => {
                log::error!("Daemon error: {}", e);
                std::process::exit(1);
            }
        }
    }

    log::info!(
        "Starting wsl-pty-bridge: shell={}, size={}x{}, cwd={:?}",
        args.shell,
        args.cols,
        args.rows,
        args.cwd
    );

    // Spawn the PTY child process.
    let child = match pty::PtyChild::spawn(
        &args.shell,
        args.cols,
        args.rows,
        args.cwd.as_deref(),
    ) {
        Ok(child) => child,
        Err(e) => {
            log::error!("Failed to spawn shell: {}", e);
            std::process::exit(1);
        }
    };

    log::info!("Child process spawned: PID {}", child.child_pid);

    // Run the event loop.
    match bridge::run(&child) {
        Ok(code) => {
            log::info!("Child exited with code {}", code);
            std::process::exit(code);
        }
        Err(e) => {
            log::error!("Bridge error: {}", e);
            std::process::exit(1);
        }
    }
}
