#!/bin/bash
# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Shared helpers for the deployer scripts. Sourced, never executed directly.

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; BOLD=''; NC=''
fi

info()  { echo -e "${BLUE}==>${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*" >&2; }
err()   { echo -e "${RED}[x]${NC} $*" >&2; }
die()   { err "$*"; exit 1; }

banner() {
  echo ""
  echo -e "${BOLD}${BLUE}======================================================${NC}"
  echo -e "${BOLD}${BLUE}  $1${NC}"
  echo -e "${BOLD}${BLUE}======================================================${NC}"
  echo ""
}

# ---------------------------------------------------------------------------
# Prompting
# ---------------------------------------------------------------------------

# ask VAR "Prompt text" ["default"]
# Reads into the named variable, falling back to the default on empty input.
# If the variable already holds a value (e.g. exported by the caller or loaded
# from config.env), that value becomes the default.
ask() {
  local __var="$1" __prompt="$2" __default="${3:-}" __current __reply
  __current="${!__var:-}"
  # Written as an if, not `[[ ]] && x`: under `set -e` an and-list whose final
  # command does not run exits the script.
  if [[ -n "$__current" ]]; then
    __default="$__current"
  fi

  # `|| true` on every read: read returns non-zero at EOF, which under `set -e`
  # would abort the caller silently the moment stdin is not a terminal — piped
  # input, a CI runner, `./deploy.sh < /dev/null`. An empty answer is a normal
  # outcome here, not a failure, so it must not propagate.
  if [[ -n "$__default" ]]; then
    read -r -p "$__prompt [$__default]: " __reply || true
    __reply="${__reply:-$__default}"
  else
    read -r -p "$__prompt: " __reply || true
  fi
  printf -v "$__var" '%s' "${__reply:-}"
}

# ask_secret VAR "Prompt text" — same as ask() but does not echo the input.
ask_secret() {
  local __var="$1" __prompt="$2" __reply
  read -r -s -p "$__prompt: " __reply || true
  echo ""
  printf -v "$__var" '%s' "${__reply:-}"
}

# confirm "Question" — returns 0 on yes, 1 on anything else. Defaults to no,
# so an EOF or a stray newline is never taken as consent.
confirm() {
  local reply
  read -r -p "$1 [y/N]: " reply || true
  [[ "${reply:-}" =~ ^[Yy]$ ]]
}

require_var() {
  local name="$1"
  [[ -n "${!name:-}" ]] || die "$name is required but was empty."
}

# ---------------------------------------------------------------------------
# Environment checks
# ---------------------------------------------------------------------------
require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is not installed. $2"
}

ensure_gcloud_auth() {
  if [[ "${CLOUD_SHELL:-}" == "true" ]]; then
    ok "Running in Google Cloud Shell; using its built-in credentials."
    return
  fi
  if gcloud auth print-access-token >/dev/null 2>&1; then
    ok "Authenticated with gcloud as $(gcloud config get-value account 2>/dev/null)."
  else
    warn "Not authenticated with gcloud. Launching login..."
    gcloud auth login
  fi
}

# ---------------------------------------------------------------------------
# Gateway binary
# ---------------------------------------------------------------------------

# fetch_gateway_binary <version> <destination>
# The gateway server ships inside the standard `claude` binary; it must be the
# native linux-x64 build, because the server uses runtime features that are not
# available when Claude Code runs under Node.
fetch_gateway_binary() {
  local version="$1" dest="$2"
  if [[ -f "$dest" ]]; then
    ok "Gateway binary already present at $dest"
    return
  fi
  info "Downloading Claude apps gateway binary v${version}..."
  curl -fsSL "https://downloads.claude.ai/claude-code-releases/${version}/linux-x64/claude" -o "$dest" \
    || die "Download failed. Check that version '${version}' exists."
  chmod +x "$dest"
  ok "Downloaded gateway binary v${version}"
}

# ---------------------------------------------------------------------------
# Configuration file (config.env)
# ---------------------------------------------------------------------------
# Persists answers between runs so re-deploying is not a re-interrogation.
# Gitignored: it holds the OAuth client secret.

load_config() {
  local f="$1"
  if [[ -f "$f" ]]; then
    # shellcheck disable=SC1090
    source "$f"
    ok "Loaded saved configuration from ${f##*/}"
  fi
}

save_config() {
  local f="$1"; shift
  # umask in a subshell, so the file is owner-only from the instant it is
  # created. A chmod afterwards would leave a window where a secret-bearing
  # file is world-readable.
  (
    umask 077
    {
      echo "# Generated by deploy.sh. Gitignored: contains the OAuth client secret."
      echo "# Delete this file to be prompted from scratch."
      for var in "$@"; do
        # %q quotes for the shell, so values with spaces, quotes, backticks, or
        # $ survive being sourced back in verbatim.
        printf '%s=%q\n' "$var" "${!var:-}"
      done
    } > "$f"
  )
  ok "Saved configuration to ${f##*/}"
}
