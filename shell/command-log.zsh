# NixOS Control shell audit log (zsh).
#
# Appends one JSON line per interactive command with its start time, duration,
# exit status, TTY and working directory. The Sessions view reads the file.
# Disable with services.nixos-control.commandLog.enable = false.
if [[ -o interactive ]] && [[ -n "${HOME:-}" ]] && [[ -z "${_NIXOS_CONTROL_HOOK:-}" ]]; then
  _NIXOS_CONTROL_HOOK=1
  autoload -Uz add-zsh-hook
  typeset -g _NIXOS_CONTROL_START
  typeset -g _NIXOS_CONTROL_CMD

  _nixos_control_preexec() {
    _NIXOS_CONTROL_START=$(command date +%s%3N 2>/dev/null) || _NIXOS_CONTROL_START=
    _NIXOS_CONTROL_CMD=$1
  }

  _nixos_control_precmd() {
    local exit_status=$?
    [[ -n "${_NIXOS_CONTROL_START:-}" && -n "${_NIXOS_CONTROL_CMD:-}" ]] || return 0

    local now duration dir cmd cwd tty
    now=$(command date +%s%3N 2>/dev/null) || return 0
    duration=$((now - _NIXOS_CONTROL_START))
    (( duration < 0 )) && duration=0

    dir="$HOME/.local/state/nixos-control"
    (umask 077; command mkdir -p "$dir" 2>/dev/null) || return 0
    command chmod 700 "$dir" 2>/dev/null || true

    cmd=$_NIXOS_CONTROL_CMD
    cwd=$PWD
    tty=${TTY:-}
    tty=${tty#/dev/}

    cmd=${cmd//\\/\\\\}
    cmd=${cmd//\"/\\\"}
    cmd=${cmd//$'\n'/\\n}
    cmd=${cmd//$'\t'/\\t}
    cmd=${cmd//$'\r'/\\r}
    cwd=${cwd//\\/\\\\}
    cwd=${cwd//\"/\\\"}

    (umask 077; print -r -- "{\"ts_ms\":$_NIXOS_CONTROL_START,\"duration_ms\":$duration,\"exit_code\":$exit_status,\"tty\":\"$tty\",\"cwd\":\"$cwd\",\"command\":\"$cmd\"}" \
      >>"$dir/commands.jsonl") 2>/dev/null || true
    command chmod 600 "$dir/commands.jsonl" 2>/dev/null || true

    _NIXOS_CONTROL_CMD=
    _NIXOS_CONTROL_START=
  }

  add-zsh-hook preexec _nixos_control_preexec
  add-zsh-hook precmd _nixos_control_precmd
fi