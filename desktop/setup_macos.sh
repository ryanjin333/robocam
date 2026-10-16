#!/usr/bin/env bash
# Install Rocam's USB receiver for the current macOS user.
set -eEuo pipefail

readonly SERVICE_LABEL="com.ryanjin.rocam.receiver"
readonly OWNERSHIP_MARKER="Rocam setup_macos.sh"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly DATA_DIR="$HOME/Library/Application Support/Rocam"
readonly LAUNCH_AGENT="$HOME/Library/LaunchAgents/${SERVICE_LABEL}.plist"
wheel=""
udid=""

usage() { cat <<'EOF'
Usage: setup_macos.sh [--wheel PATH] [--udid DEVICE_ID]

Installs the USB receiver for this desktop user. It starts at login with
`rocam-webcam --usb --fps 30`; microphone forwarding remains off.
EOF
}
while (($#)); do
  case "$1" in
    --wheel) wheel=${2:?--wheel requires a path}; shift 2 ;;
    --udid) udid=${2:?--udid requires a device ID}; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done
fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
safe_path() { [[ ! -L "$1" ]] || fail "refusing symbolic-link destination: $1"; }
owned_file() { [[ -f "$1" && ! -L "$1" ]] && grep -Fq "$OWNERSHIP_MARKER" "$1"; }
[[ ${EUID:-$(id -u)} -ne 0 ]] || fail "run this setup as the desktop user, not root"
[[ -z "$udid" || "$udid" =~ ^([[:xdigit:]]{40}|[[:xdigit:]]{8}-[[:xdigit:]]{16})$ ]] || fail "--udid must be a valid iPhone or iPad UDID"
safe_path "$DATA_DIR"; safe_path "$LAUNCH_AGENT"
if [[ -e "$DATA_DIR" && ! -f "$DATA_DIR/.rocam-owned" ]]; then fail "existing Rocam data is not managed by this setup"; fi
if [[ -e "$LAUNCH_AGENT" ]] && ! owned_file "$LAUNCH_AGENT"; then fail "existing LaunchAgent is not managed by this setup"; fi

if ! command -v brew >/dev/null 2>&1; then
  cat >&2 <<'EOF'
Homebrew is needed to install iproxy and Python 3.12. Install Homebrew using
the instructions at https://brew.sh/, then run this setup again.
EOF
  exit 1
fi
if ! command -v iproxy >/dev/null 2>&1 || ! command -v python3.12 >/dev/null 2>&1; then brew install libusbmuxd python@3.12; fi
if [[ ! -d /Applications/OBS.app ]]; then brew install --cask obs; fi
python_bin="$(command -v python3.12)"
brew_bin="$(brew --prefix libusbmuxd)/bin"
iproxy_path="$brew_bin/iproxy"; [[ -x "$iproxy_path" ]] || iproxy_path="$(command -v iproxy || true)"
[[ -n "$iproxy_path" ]] || fail "iproxy was not installed by libusbmuxd"
"$iproxy_path" --help 2>&1 | grep -q -- '--local' || fail "iproxy does not support --local"
"$iproxy_path" --help 2>&1 | grep -q -- '--source' || fail "iproxy does not support --source"
if [[ -z "$wheel" ]]; then wheel="$(find "$SCRIPT_DIR" -maxdepth 1 -name 'rocam_webcam-*.whl' -type f -print -quit 2>/dev/null || true)"; fi
if [[ -z "$wheel" ]]; then wheel="$(find "$SCRIPT_DIR/dist" -maxdepth 1 -name 'rocam_webcam-*.whl' -type f -print -quit 2>/dev/null || true)"; fi
if [[ -n "$wheel" ]]; then [[ -f "$wheel" && "$wheel" == *.whl ]] || fail "--wheel must be a local Rocam wheel"; fi

uid="$(id -u)"
old_plist=""; old_venv=""
if [[ -f "$LAUNCH_AGENT" ]]; then old_plist="$(mktemp)"; cp "$LAUNCH_AGENT" "$old_plist"; launchctl bootout "gui/$uid/$SERVICE_LABEL" 2>/dev/null || true; fi
if ! "$python_bin" - <<'PY'
import socket
with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener: listener.bind(("127.0.0.1", 8765))
PY
then
  [[ -n "$old_plist" ]] && launchctl bootstrap "gui/$uid" "$LAUNCH_AGENT" 2>/dev/null || true
  fail "127.0.0.1:8765 is already in use; leave the existing receiver untouched"
fi
mkdir -p "$DATA_DIR" "$(dirname -- "$LAUNCH_AGENT")"
printf 'owned\n' >"$DATA_DIR/.rocam-owned"
safe_path "$DATA_DIR/venv"
if [[ -d "$DATA_DIR/venv" ]]; then old_venv="$DATA_DIR/venv.backup.$$"; mv "$DATA_DIR/venv" "$old_venv"; fi
rollback() {
  launchctl bootout "gui/$uid/$SERVICE_LABEL" 2>/dev/null || true
  rm -f "$LAUNCH_AGENT"
  rm -rf -- "$DATA_DIR/venv"
  [[ -n "$old_venv" && -d "$old_venv" ]] && mv "$old_venv" "$DATA_DIR/venv"
  [[ -n "$old_plist" && -f "$old_plist" ]] && { mv "$old_plist" "$LAUNCH_AGENT"; launchctl bootstrap "gui/$uid" "$LAUNCH_AGENT" 2>/dev/null || true; }
}
trap rollback ERR
"$python_bin" -m venv "$DATA_DIR/venv"
if [[ -n "$wheel" ]]; then "$DATA_DIR/venv/bin/python" -m pip install --upgrade --force-reinstall "$wheel"; else "$DATA_DIR/venv/bin/python" -m pip install --upgrade --force-reinstall "$SCRIPT_DIR"; fi
"$DATA_DIR/venv/bin/rocam-webcam" --help
"$python_bin" - "$LAUNCH_AGENT" "$DATA_DIR/venv/bin/rocam-webcam" "$brew_bin" "$DATA_DIR" "$SERVICE_LABEL" "$udid" <<'PY'
import plistlib, sys
path, receiver, brew_bin, data_dir, label, udid = sys.argv[1:]
args = [receiver, "--usb", "--fps", "30"]
if udid: args += ["--udid", udid]
with open(path, "wb") as output:
    plistlib.dump({"Label": label, "RocamManagedBy": "Rocam setup_macos.sh", "ProgramArguments": args,
                    "EnvironmentVariables": {"PATH": brew_bin + ":/usr/bin:/bin"}, "RunAtLoad": True,
                    "KeepAlive": True, "StandardOutPath": data_dir + "/receiver.log",
                    "StandardErrorPath": data_dir + "/receiver-error.log"}, output)
PY
plutil -lint "$LAUNCH_AGENT" >/dev/null
launchctl bootstrap "gui/$uid" "$LAUNCH_AGENT"
trap - ERR
rm -f "$old_plist"; rm -rf -- "$old_venv"
cat <<'EOF'
Rocam will start automatically after login using USB at 30 FPS. Connect and
trust the iPhone or iPad, then keep the Rocam app open. OBS Virtual Camera is
installed if needed, but macOS requires you to approve its existing extension:
System Settings > General > Login Items & Extensions > Camera Extensions.
Open OBS after approving it and start then stop Virtual Camera once. This
setup does not enable microphone forwarding.
EOF
