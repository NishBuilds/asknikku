#!/usr/bin/env bash
set -euo pipefail

PREFIX="${HOME}/.local/bin"
HOOK_PATH="${HOME}/.asknikku-shell-hook.sh"
BASHRC="${HOME}/.bashrc"
ZSHRC="${HOME}/.zshrc"

mkdir -p "$PREFIX"

cat > "$PREFIX/asknikku" <<'PYEOF'
#!/usr/bin/env python3
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

DEFAULT_HOST = os.environ.get("ASKNIKKU_HOST", "<PUT YOUR OLLAMA DEVICE HOST IP HERE>")
DEFAULT_PORT = os.environ.get("ASKNIKKU_PORT", "<SPECIFY YOUR OLLAMA PORT, USUALLY 11434>")
DEFAULT_MODEL = os.environ.get("ASKNIKKU_MODEL", "qwen2.5:7b")
MAX_ASKNIKKU_HISTORY = 6

STATE_DIR = Path(
    os.environ.get(
        "ASKNIKKU_STATE_DIR",
        Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state")) / "asknikku",
    )
)
LAST_OUTPUT_FILE = STATE_DIR / "last_output.txt"
LAST_COMMAND_FILE = STATE_DIR / "last_command.txt"
ASKNIKKU_HISTORY_FILE = STATE_DIR / "asknikku_history.json"
ASKNIKKU_ANCHOR_FILE = STATE_DIR / "asknikku_anchor.json"
API_URL = f"http://{DEFAULT_HOST}:{DEFAULT_PORT}/api/generate"

HELP_TEXT = """asknikku — query your remote Ollama model from the terminal

Usage:
  asknikku "your prompt"
  asknikku -a "question about the last captured terminal output"
  asknikku -b "follow-up about the asknikku exchange history, anchored to the original terminal output when available"
  asknikku -model="MODELNAME" "your prompt"
  asknikku -a -model="MODELNAME" "question about the last captured output"
  asknikku -b -model="MODELNAME" "follow-up using a different model"

Flags:
  -a
      Use the most recently captured shell command and shell output as context.
      asknikku itself is always skipped by the shell hook, so -a always refers
      to the last proper terminal command/output.

  -b
      Use the last 6 asknikku exchanges as context.
      The newest prior exchange is marked as the one to focus on.
      The 5 older prior exchanges are marked as background memory/context.
      If the asknikku conversation started right after a real terminal command/output,
      that original terminal command/output is also included as an anchor.
      You cannot combine -a and -b in the same command.

  -model="MODELNAME"
      Override the default model just for this command.
      Example: asknikku -model="llama3.1:8b" "summarize this"

Examples:
  asknikku "tell me about Antarctica"
  asknikku -a "what does this error mean"
  asknikku -b "can you say more?"
  asknikku -b "what part of your last answer matters most?"
  asknikku -a -model="qwen2.5:14b" "what should I do next"

Control shell capture if a fullscreen app conflicts:
  asknikku-capture off
  asknikku-capture on
  asknikku-capture status
"""

def fail(message: str, code: int = 1) -> None:
    print(f"asknikku: {message}", file=sys.stderr)
    sys.exit(code)

def ensure_state_dir() -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)

def parse_args(argv):
    include_last_output = False
    include_asknikku_history = False
    model = DEFAULT_MODEL
    prompt_parts = []

    for arg in argv:
        if arg == "-a":
            include_last_output = True
        elif arg == "-b":
            include_asknikku_history = True
        elif arg.startswith("-model=") or arg.startswith("--model="):
            model = arg.split("=", 1)[1].strip()
            if not model:
                fail("the model override cannot be empty.")
        elif arg in ("-h", "--help", "help"):
            print(HELP_TEXT)
            sys.exit(0)
        else:
            prompt_parts.append(arg)

    if include_last_output and include_asknikku_history:
        fail("you cannot use -a and -b together.")
    if not prompt_parts:
        print(HELP_TEXT)
        sys.exit(0)

    prompt = " ".join(prompt_parts).strip()
    if not prompt:
        print(HELP_TEXT)
        sys.exit(0)

    return include_last_output, include_asknikku_history, model, prompt

def read_text_file(path: Path, missing_message: str) -> str:
    if not path.exists():
        fail(missing_message)
    text = path.read_text(encoding="utf-8", errors="replace").strip()
    if not text:
        fail(missing_message)
    return text

def read_last_output() -> str:
    return read_text_file(
        LAST_OUTPUT_FILE,
        "no captured terminal output found. Open a new shell after installing, run a normal command, then try asknikku -a again.",
    )

def read_last_command() -> str:
    if LAST_COMMAND_FILE.exists():
        return LAST_COMMAND_FILE.read_text(encoding="utf-8", errors="replace").strip()
    return ""

def load_asknikku_history():
    if not ASKNIKKU_HISTORY_FILE.exists():
        fail("no previous asknikku exchange found. Run asknikku once, then try asknikku -b.")
    try:
        data = json.loads(ASKNIKKU_HISTORY_FILE.read_text(encoding="utf-8", errors="replace"))
    except json.JSONDecodeError:
        fail("asknikku history file is corrupted.")
    if not isinstance(data, list) or not data:
        fail("no previous asknikku exchange found. Run asknikku once, then try asknikku -b.")

    cleaned = []
    for item in data:
        if not isinstance(item, dict):
            continue
        prompt = str(item.get("prompt", "")).strip()
        response = str(item.get("response", "")).strip()
        if prompt and response:
            cleaned.append({"prompt": prompt, "response": response})

    if not cleaned:
        fail("no previous asknikku exchange found. Run asknikku once, then try asknikku -b.")
    return cleaned[-MAX_ASKNIKKU_HISTORY:]

def load_anchor():
    if not ASKNIKKU_ANCHOR_FILE.exists():
        return None
    try:
        data = json.loads(ASKNIKKU_ANCHOR_FILE.read_text(encoding="utf-8", errors="replace"))
    except json.JSONDecodeError:
        return None
    if not isinstance(data, dict):
        return None
    command = str(data.get("command", "")).strip()
    output = str(data.get("output", "")).strip()
    if not command and not output:
        return None
    return {"command": command, "output": output}

def build_prompt(user_prompt: str, include_last_output: bool, include_asknikku_history: bool) -> str:
    if include_last_output:
        last_output = read_last_output()
        last_command = read_last_command()
        parts = ["Answer the user's question using the terminal context below."]
        if last_command:
            parts.append(f"Last captured shell command:\n{last_command}")
        parts.append(f"Last captured terminal output:\n{last_output}")
        parts.append(f"User question:\n{user_prompt}")
        return "\n\n".join(parts)

    if include_asknikku_history:
        history = load_asknikku_history()
        focused = history[-1]
        background = history[:-1]
        anchor = load_anchor()

        parts = [
            "Answer the user's follow-up using the asknikku conversation history below.",
            "Focus primarily on the most recent prior exchange.",
            "Use the older prior exchanges as background memory and context only.",
        ]

        if anchor:
            parts.extend([
                "",
                "ORIGINAL TERMINAL ANCHOR FOR THIS ASKNIKKU CONVERSATION:",
                "This is the real terminal command/output that happened right before the user started interacting with asknikku.",
                "Use it to anchor the meaning of the ongoing follow-up conversation when relevant.",
            ])
            if anchor.get("command"):
                parts.append(f"Anchor shell command:\n{anchor['command']}")
            if anchor.get("output"):
                parts.append(f"Anchor terminal output:\n{anchor['output']}")

        parts.extend([
            "",
            "MOST RECENT PRIOR EXCHANGE TO FOCUS ON:",
            f"User prompt:\n{focused['prompt']}",
            f"Asknikku response:\n{focused['response']}",
        ])

        if background:
            parts.append("")
            parts.append("OLDER PRIOR EXCHANGES FOR MEMORY AND CONTEXT:")
            for idx, item in enumerate(reversed(background), start=1):
                parts.append(f"Older exchange {idx}:")
                parts.append(f"User prompt:\n{item['prompt']}")
                parts.append(f"Asknikku response:\n{item['response']}")
                parts.append("")

        parts.append(f"New user follow-up:\n{user_prompt}")
        return "\n\n".join(parts)

    return user_prompt

def query_ollama(prompt: str, model: str) -> str:
    payload = json.dumps({"model": model, "prompt": prompt, "stream": False}).encode("utf-8")
    req = urllib.request.Request(
        API_URL,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(req, timeout=180) as response:
            body = response.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        details = exc.read().decode("utf-8", errors="replace")
        fail(f"server returned HTTP {exc.code}. {details}")
    except urllib.error.URLError as exc:
        fail(f"could not reach Ollama at {API_URL}. Check that the Mac is reachable and Ollama is listening on the network. Details: {exc.reason}")

    try:
        parsed = json.loads(body)
    except json.JSONDecodeError:
        fail(f"received invalid JSON from Ollama: {body[:500]}")

    response_text = parsed.get("response", "").strip()
    if not response_text:
        fail("received an empty response from Ollama.")
    return response_text

def store_asknikku_exchange(user_prompt: str, answer: str) -> None:
    ensure_state_dir()
    history = []
    if ASKNIKKU_HISTORY_FILE.exists():
        try:
            existing = json.loads(ASKNIKKU_HISTORY_FILE.read_text(encoding="utf-8", errors="replace"))
            if isinstance(existing, list):
                history = existing
        except json.JSONDecodeError:
            history = []

    cleaned = []
    for item in history:
        if isinstance(item, dict):
            prompt = str(item.get("prompt", "")).strip()
            response = str(item.get("response", "")).strip()
            if prompt and response:
                cleaned.append({"prompt": prompt, "response": response})

    cleaned.append({"prompt": user_prompt, "response": answer})
    trimmed = cleaned[-MAX_ASKNIKKU_HISTORY:]
    ASKNIKKU_HISTORY_FILE.write_text(json.dumps(trimmed, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

def snapshot_terminal_anchor_if_needed() -> None:
    ensure_state_dir()
    history_exists = False
    if ASKNIKKU_HISTORY_FILE.exists():
        try:
            existing = json.loads(ASKNIKKU_HISTORY_FILE.read_text(encoding="utf-8", errors="replace"))
            history_exists = isinstance(existing, list) and len(existing) > 0
        except json.JSONDecodeError:
            history_exists = False

    if history_exists:
        return

    command = LAST_COMMAND_FILE.read_text(encoding="utf-8", errors="replace").strip() if LAST_COMMAND_FILE.exists() else ""
    output = LAST_OUTPUT_FILE.read_text(encoding="utf-8", errors="replace").strip() if LAST_OUTPUT_FILE.exists() else ""

    if not command and not output:
        return

    anchor = {"command": command, "output": output}
    ASKNIKKU_ANCHOR_FILE.write_text(json.dumps(anchor, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

def main() -> None:
    include_last_output, include_asknikku_history, model, prompt = parse_args(sys.argv[1:])
    snapshot_terminal_anchor_if_needed()
    full_prompt = build_prompt(prompt, include_last_output, include_asknikku_history)
    answer = query_ollama(full_prompt, model)
    print(answer)
    store_asknikku_exchange(prompt, answer)

if __name__ == "__main__":
    main()
PYEOF

cat > "$PREFIX/asknikku-capture" <<'BASHEOF'
#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${ASKNIKKU_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/asknikku}"
DISABLED_FILE="$STATE_DIR/capture_disabled"
mkdir -p "$STATE_DIR"

case "${1:-status}" in
  on|enable)
    rm -f "$DISABLED_FILE"
    echo "asknikku capture is ON"
    ;;
  off|disable|pause)
    : > "$DISABLED_FILE"
    echo "asknikku capture is OFF"
    ;;
  status)
    if [[ -f "$DISABLED_FILE" ]]; then
      echo "asknikku capture is OFF"
    else
      echo "asknikku capture is ON"
    fi
    ;;
  *)
    echo "Usage: asknikku-capture {on|off|status}" >&2
    exit 1
    ;;
esac
BASHEOF

cat > "$HOOK_PATH" <<'BASHEOF'
# asknikku shell integration
# Preserves the last non-empty captured shell output.
# Skips full-screen / interactive commands and always skips asknikku itself.
# asknikku follow-up memory is handled directly inside the Python script.

if [[ $- != *i* ]]; then
  return 0 2>/dev/null || exit 0
fi

export ASKNIKKU_STATE_DIR="${ASKNIKKU_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/asknikku}"
mkdir -p "$ASKNIKKU_STATE_DIR"

_asknikku_capture_disabled() {
  [[ -f "$ASKNIKKU_STATE_DIR/capture_disabled" ]]
}

_asknikku_should_skip_command() {
  local cmd="$1"
  [[ -z "$cmd" ]] && return 0
  _asknikku_capture_disabled && return 0

  local first="$cmd"

  while [[ "$first" == *=* && "$first" != *" "* ]]; do
    cmd="${cmd#* }"
    first="${cmd%% *}"
  done

  first="${cmd%% *}"

  if [[ "$first" == "sudo" ]]; then
    local rest="${cmd#sudo }"
    while [[ "$rest" == -* ]]; do
      rest="${rest#* }"
    done
    first="${rest%% *}"
    cmd="$rest"
  fi

  if [[ "$first" == "asknikku" ]]; then
    return 0
  fi

  case "$first" in
    vim|nvim|nano|emacs|vi|view|less|more|man|top|htop|btop|watch|tmux|screen|ssh|sftp|mosh|fzf|ranger|mc|python|python3|ipython|node|irb|lua|php|ruby|perl|psql|mysql|sqlite3|redis-cli|mongosh|journalctl|tail|kubectl)
      return 0
      ;;
  esac

  return 1
}

_asknikku_capture_start() {
  [[ -n "${ASKNIKKU_CAPTURE_ACTIVE:-}" ]] && return

  local cmd="$1"
  _asknikku_should_skip_command "$cmd" && return

  mkdir -p "$ASKNIKKU_STATE_DIR"
  printf '%s\n' "$cmd" > "$ASKNIKKU_STATE_DIR/current_command.txt"
  : > "$ASKNIKKU_STATE_DIR/current_output.txt"

  exec {ASKNIKKU_STDOUT_SAVED}>&1 {ASKNIKKU_STDERR_SAVED}>&2
  exec > >(
    tee "$ASKNIKKU_STATE_DIR/current_output.txt" >&${ASKNIKKU_STDOUT_SAVED}
  ) 2>&1
  export ASKNIKKU_CAPTURE_ACTIVE=1
}

_asknikku_capture_stop() {
  [[ -z "${ASKNIKKU_CAPTURE_ACTIVE:-}" ]] && return
  exec 1>&${ASKNIKKU_STDOUT_SAVED} 2>&${ASKNIKKU_STDERR_SAVED}
  exec {ASKNIKKU_STDOUT_SAVED}>&- {ASKNIKKU_STDERR_SAVED}>&-

  if [[ -s "$ASKNIKKU_STATE_DIR/current_output.txt" ]]; then
    mv "$ASKNIKKU_STATE_DIR/current_output.txt" "$ASKNIKKU_STATE_DIR/last_output.txt"
    mv "$ASKNIKKU_STATE_DIR/current_command.txt" "$ASKNIKKU_STATE_DIR/last_command.txt"
  else
    rm -f "$ASKNIKKU_STATE_DIR/current_output.txt" "$ASKNIKKU_STATE_DIR/current_command.txt"
  fi

  unset ASKNIKKU_STDOUT_SAVED ASKNIKKU_STDERR_SAVED ASKNIKKU_CAPTURE_ACTIVE
}

if [[ -n "${BASH_VERSION:-}" ]]; then
  _asknikku_preexec_bash() {
    [[ -n "${COMP_LINE:-}" ]] && return
    local cmd="$BASH_COMMAND"
    case "$cmd" in
      _asknikku_capture_start*|_asknikku_capture_stop*|history*|trap*|PROMPT_COMMAND=* ) return ;;
    esac
    _asknikku_capture_start "$cmd"
  }

  trap '_asknikku_preexec_bash' DEBUG

  if [[ -n "${PROMPT_COMMAND:-}" ]]; then
    PROMPT_COMMAND="_asknikku_capture_stop; $PROMPT_COMMAND"
  else
    PROMPT_COMMAND="_asknikku_capture_stop"
  fi
elif [[ -n "${ZSH_VERSION:-}" ]]; then
  autoload -Uz add-zsh-hook

  _asknikku_preexec_zsh() {
    _asknikku_capture_start "$1"
  }

  _asknikku_precmd_zsh() {
    _asknikku_capture_stop
  }

  add-zsh-hook preexec _asknikku_preexec_zsh
  add-zsh-hook precmd _asknikku_precmd_zsh
fi
BASHEOF

chmod 0755 "$PREFIX/asknikku" "$PREFIX/asknikku-capture"
chmod 0644 "$HOOK_PATH"

ensure_line() {
  local file="$1"
  local line="$2"
  touch "$file"
  grep -Fqx "$line" "$file" || printf '\n%s\n' "$line" >> "$file"
}

ensure_path_line() {
  local file="$1"
  local line='export PATH="$HOME/.local/bin:$PATH"'
  touch "$file"
  grep -Fqx "$line" "$file" || printf '\n%s\n' "$line" >> "$file"
}

ensure_path_line "$BASHRC"
ensure_path_line "$ZSHRC"
ensure_line "$BASHRC" '[[ -f "$HOME/.asknikku-shell-hook.sh" ]] && source "$HOME/.asknikku-shell-hook.sh"'
ensure_line "$ZSHRC" '[[ -f "$HOME/.asknikku-shell-hook.sh" ]] && source "$HOME/.asknikku-shell-hook.sh"'

cat <<EOF
Installed asknikku to $PREFIX/asknikku
Installed asknikku-capture to $PREFIX/asknikku-capture
Installed shell hook to $HOOK_PATH

Next:
  source "$BASHRC"   # bash
  # or
  source "$ZSHRC"    # zsh

Examples:
  asknikku "tell me about Antarctica"
  asknikku -a "what does this error mean"
  asknikku -b "can you say more?"
  asknikku -b "what part of your last answer matters most?"
  asknikku -a -model="llama3.1:8b" "what should I do next"

If an unlisted fullscreen app conflicts:
  asknikku-capture off
  # run the app
  asknikku-capture on
EOF
