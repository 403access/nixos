# NixOS Control shell audit log (bash).
#
# Appends one JSON line per interactive command with its start time, duration,
# exit status, TTY and working directory. The Sessions view reads the file.
# Disable with services.nixos-control.commandLog.enable = false.
if [ -n "${HOME:-}" ] && [ -z "${_NIXOS_CONTROL_HOOK:-}" ]; then
  _NIXOS_CONTROL_HOOK=1

  # Timestamped history is a fallback when another DEBUG trap already exists.
  HISTTIMEFORMAT="${HISTTIMEFORMAT:-%F %T }"
  _NIXOS_CONTROL_AT_PROMPT=0
  _NIXOS_CONTROL_ARMED=0
  _NIXOS_CONTROL_LAST_HISTCMD=${HISTCMD:-0}

  _nixos_control_debug() {
    case "${BASH_COMMAND:-}" in
      _nixos_control_* | PROMPT_COMMAND*) return ;;
    esac
    if [ "${_NIXOS_CONTROL_AT_PROMPT:-0}" = 1 ]; then
      _NIXOS_CONTROL_AT_PROMPT=0
      _NIXOS_CONTROL_START=$(command date +%s%3N 2>/dev/null) || _NIXOS_CONTROL_START=
      _NIXOS_CONTROL_ARMED=1
    fi
  }

  _nixos_control_capture_status() {
    _NIXOS_CONTROL_STATUS=$?
  }

  _nixos_control_log_command() {
    local status=${_NIXOS_CONTROL_STATUS:-$?}
    local line ts cmd now start duration dir cwd tty

    # An empty prompt (or a freshly started shell) must not re-log the previous
    # history entry.
    if [ -n "${HISTCMD:-}" ] \
      && [ "$HISTCMD" = "${_NIXOS_CONTROL_LAST_HISTCMD:-}" ] \
      && [ "${_NIXOS_CONTROL_ARMED:-0}" != 1 ]; then
      _NIXOS_CONTROL_AT_PROMPT=1
      return 0
    fi

    line=$(HISTTIMEFORMAT='%s ' history 1 2>/dev/null) || {
      _NIXOS_CONTROL_AT_PROMPT=1
      return 0
    }
    if [[ $line =~ ^[[:space:]]*[0-9]+[[:space:]]+([0-9]+)[[:space:]]+(.*)$ ]]; then
      ts=${BASH_REMATCH[1]}
      cmd=${BASH_REMATCH[2]}
    else
      _NIXOS_CONTROL_AT_PROMPT=1
      return 0
    fi

    # Require a plausible epoch: an untimestamped entry whose command starts
    # with digits must not be mistaken for one.
    if [ "${#ts}" -lt 9 ] || [ -z "$cmd" ]; then
      _NIXOS_CONTROL_AT_PROMPT=1
      return 0
    fi

    now=$(command date +%s%3N 2>/dev/null) || {
      _NIXOS_CONTROL_AT_PROMPT=1
      return 0
    }
    if [ "${_NIXOS_CONTROL_ARMED:-0}" = 1 ] && [ -n "${_NIXOS_CONTROL_START:-}" ]; then
      start=$_NIXOS_CONTROL_START
    else
      start=$((ts * 1000))
    fi
    if [ "$start" -gt "$now" ]; then
      _NIXOS_CONTROL_ARMED=0
      _NIXOS_CONTROL_AT_PROMPT=1
      return 0
    fi
    duration=$((now - start))
    (( duration < 0 )) && duration=0

    if [ "$start|$cmd" = "${_NIXOS_CONTROL_LAST:-}" ]; then
      _NIXOS_CONTROL_ARMED=0
      _NIXOS_CONTROL_AT_PROMPT=1
      return 0
    fi
    _NIXOS_CONTROL_LAST="$start|$cmd"
    _NIXOS_CONTROL_ARMED=0

    dir="$HOME/.local/state/nixos-control"
    (umask 077; command mkdir -p "$dir" 2>/dev/null) || {
      _NIXOS_CONTROL_AT_PROMPT=1
      return 0
    }
    command chmod 700 "$dir" 2>/dev/null || true

    cwd=$PWD
    tty=$(command tty 2>/dev/null) || tty=
    tty=${tty#/dev/}

    cmd=${cmd//\\/\\\\}
    cmd=${cmd//\"/\\\"}
    cmd=${cmd//$'\n'/\\n}
    cmd=${cmd//$'\t'/\\t}
    cmd=${cmd//$'\r'/\\r}
    cwd=${cwd//\\/\\\\}
    cwd=${cwd//\"/\\\"}

    (umask 077; printf '{"ts_ms":%s,"duration_ms":%s,"exit_code":%s,"tty":"%s","cwd":"%s","command":"%s"}\n' \
      "$start" "$duration" "$status" "$tty" "$cwd" "$cmd" \
      >>"$dir/commands.jsonl") 2>/dev/null || true
    command chmod 600 "$dir/commands.jsonl" 2>/dev/null || true

    _NIXOS_CONTROL_LAST_HISTCMD=${HISTCMD:-0}
    _NIXOS_CONTROL_AT_PROMPT=1
  }

  # Keep a user's own DEBUG trap intact; without it the history timestamp is
  # still usable as an approximate start time.
  if [ -z "$(trap -p DEBUG 2>/dev/null || true)" ]; then
    trap '_nixos_control_debug' DEBUG
  fi

  PROMPT_COMMAND="_nixos_control_capture_status${PROMPT_COMMAND:+; $PROMPT_COMMAND}; _nixos_control_log_command"
fi