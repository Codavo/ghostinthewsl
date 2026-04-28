# GhostInTheWSL shell integration for Fish
#
# Source this file in your config.fish:
#   if test -f /opt/ghostwsl/shell-integration/ghostwsl.fish
#       source /opt/ghostwsl/shell-integration/ghostwsl.fish
#   end
#
# Features:
#   - Reports CWD changes via OSC 7 (understood by Ghostty for new splits/tabs)
#   - Reports current command via OSC 133 (shell integration marks)
#   - Sets terminal title to user@host:cwd

# Only activate if running inside GhostInTheWSL
if not set -q GHOSTWSL
    exit 0
end

if set -q __ghostwsl_initialized
    exit 0
end
set -g __ghostwsl_initialized 1

# Report CWD via OSC 7
function __ghostwsl_osc7 --on-variable PWD
    printf '\e]7;file://%s%s\e\\' (hostname) $PWD
end

# OSC 133 semantic prompt markers
function __ghostwsl_prompt_start --on-event fish_prompt
    printf '\e]133;A\e\\'
end

function __ghostwsl_preexec --on-event fish_preexec
    printf '\e]133;C\e\\'
end

function __ghostwsl_postexec --on-event fish_postexec
    printf '\e]133;D;%d\e\\' $status
end

# Set window title
function __ghostwsl_title --on-event fish_prompt
    printf '\e]0;%s@%s:%s\a' $USER (hostname) (prompt_pwd)
end

# Windows program launcher helpers
function open --description "Open file/folder in Windows Explorer"
    set -l target $argv[1]
    if test -z "$target"
        set target "."
    end
    set -l winpath (wslpath -w "$target" 2>/dev/null; or echo "$target")
    explorer.exe "$winpath" 2>/dev/null &
end

function wstart --description "Open with Windows default application"
    set -l target $argv[1]
    if test -z "$target"
        set target "."
    end
    set -l winpath (wslpath -w "$target" 2>/dev/null; or echo "$target")
    cmd.exe /c start "" "$winpath" 2>/dev/null &
end

# Report initial CWD
__ghostwsl_osc7
