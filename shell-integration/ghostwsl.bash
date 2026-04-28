# GhostInTheWSL shell integration for Bash
#
# Source this file in your .bashrc:
#   [ -f /opt/ghostwsl/shell-integration/ghostwsl.bash ] && source /opt/ghostwsl/shell-integration/ghostwsl.bash
#
# Features:
#   - Reports CWD changes via OSC 7 (understood by Ghostty for new splits/tabs)
#   - Reports current command via OSC 133 (shell integration marks)
#   - Sets terminal title to user@host:cwd

# Only activate if running inside GhostInTheWSL
if [ -z "$GHOSTWSL" ]; then
    return 0 2>/dev/null || exit 0
fi

# Report CWD via OSC 7 after each command
__ghostwsl_osc7() {
    local hostname
    hostname=$(hostname)
    printf '\e]7;file://%s%s\e\\' "$hostname" "$PWD"
}

# Report command start/end via OSC 133 (semantic prompts)
__ghostwsl_prompt_start() {
    printf '\e]133;A\e\\'
}

__ghostwsl_prompt_end() {
    printf '\e]133;B\e\\'
}

__ghostwsl_preexec() {
    printf '\e]133;C\e\\'
}

__ghostwsl_precmd() {
    local exit_code=$?
    printf '\e]133;D;%d\e\\' "$exit_code"
    __ghostwsl_osc7
    __ghostwsl_prompt_start
}

# Set up the prompt hooks
if [[ -z "$__ghostwsl_initialized" ]]; then
    __ghostwsl_initialized=1

    # Add to PROMPT_COMMAND
    if [[ -z "$PROMPT_COMMAND" ]]; then
        PROMPT_COMMAND="__ghostwsl_precmd"
    elif [[ "$PROMPT_COMMAND" != *"__ghostwsl_precmd"* ]]; then
        PROMPT_COMMAND="__ghostwsl_precmd;$PROMPT_COMMAND"
    fi

    # Trap DEBUG for preexec equivalent
    trap '__ghostwsl_preexec' DEBUG

    # Set window title
    PS1='\[\e]0;\u@\h:\w\a\]'"$PS1"

    # Report initial CWD
    __ghostwsl_osc7

    # Windows program launcher helpers.
    # These translate WSL paths to Windows paths automatically.

    # Open files/folders in Windows Explorer
    open() {
        local target="${1:-.}"
        local winpath
        winpath=$(wslpath -w "$target" 2>/dev/null) || winpath="$target"
        explorer.exe "$winpath" 2>/dev/null &
    }

    # Open in Windows default application
    wstart() {
        local target="${1:-.}"
        local winpath
        winpath=$(wslpath -w "$target" 2>/dev/null) || winpath="$target"
        cmd.exe /c start "" "$winpath" 2>/dev/null &
    }
fi
