# GhostInTheWSL shell integration for Zsh
#
# Source this file in your .zshrc:
#   [ -f /opt/ghostwsl/shell-integration/ghostwsl.zsh ] && source /opt/ghostwsl/shell-integration/ghostwsl.zsh
#
# Features:
#   - Reports CWD changes via OSC 7 (understood by Ghostty for new splits/tabs)
#   - Reports current command via OSC 133 (shell integration marks)
#   - Sets terminal title to user@host:cwd

# Only activate if running inside GhostInTheWSL
if [[ -z "$GHOSTWSL" ]]; then
    return 0 2>/dev/null || exit 0
fi

# Report CWD via OSC 7
__ghostwsl_osc7() {
    printf '\e]7;file://%s%s\e\\' "$(hostname)" "$PWD"
}

# OSC 133 semantic prompt markers
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
}

if [[ -z "$__ghostwsl_initialized" ]]; then
    __ghostwsl_initialized=1

    # Use Zsh hooks
    autoload -Uz add-zsh-hook
    add-zsh-hook precmd __ghostwsl_precmd
    add-zsh-hook preexec __ghostwsl_preexec

    # Set window title via precmd
    add-zsh-hook precmd () {
        print -Pn '\e]0;%n@%m:%~\a'
    }

    # Wrap prompt with OSC 133 markers
    if [[ -z "$__ghostwsl_prompt_wrapped" ]]; then
        __ghostwsl_prompt_wrapped=1
        PS1="%{$(__ghostwsl_prompt_start)%}${PS1}%{$(__ghostwsl_prompt_end)%}"
    fi

    # Report initial CWD
    __ghostwsl_osc7

    # Windows program launcher helpers.
    open() {
        local target="${1:-.}"
        local winpath
        winpath=$(wslpath -w "$target" 2>/dev/null) || winpath="$target"
        explorer.exe "$winpath" 2>/dev/null &!
    }

    wstart() {
        local target="${1:-.}"
        local winpath
        winpath=$(wslpath -w "$target" 2>/dev/null) || winpath="$target"
        cmd.exe /c start "" "$winpath" 2>/dev/null &!
    }
fi
