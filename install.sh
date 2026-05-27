#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yaml"

CONTAINER_NAME="${CONTAINER_NAME:-code-server}"
CONTAINER_USER="${CONTAINER_USER:-coder}"
NODE_MAJOR="${NODE_MAJOR:-22}"
CODEX_PACKAGE="${CODEX_PACKAGE:-@openai/codex}"

ASSUME_YES=0
DIRECT_MODE=0
SKIP_LOGIN=0
SKIP_COMPOSE_VOLUME=0
COMPOSE_CHANGED=0
DOCKER_CMD=()

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

code-server Docker 컨테이너 안에 Node.js/npm과 Codex CLI를 설치합니다.
기본 실행 위치는 docker-compose.yaml이 있는 github-shared 디렉터리입니다.

Options:
  -y, --yes                 확인 질문을 모두 승인합니다.
  --container NAME          대상 컨테이너 이름입니다. 기본값: code-server
  --user USER               컨테이너 안의 설치 사용자입니다. 기본값: coder
  --node-major VERSION      필요 시 설치할 Node.js 메이저 버전입니다. 기본값: 22
  --package PACKAGE         설치할 Codex CLI npm 패키지입니다. 기본값: @openai/codex
  --skip-login              설치 후 device auth 로그인을 시작하지 않습니다.
  --direct                  현재 셸에서 직접 설치합니다. 컨테이너 안에서 실행할 때 사용합니다.
  --no-compose-volume       docker-compose.yaml의 .codex 볼륨 자동 추가를 건너뜁니다.
  -h, --help                도움말을 표시합니다.

Examples:
  ./install.sh
  ./install.sh --yes --skip-login
  ./install.sh --container code-server --user coder
EOF
}

log() {
  printf '[install] %s\n' "$*"
}

warn() {
  printf '[warn] %s\n' "$*" >&2
}

die() {
  printf '[error] %s\n' "$*" >&2
  exit 1
}

confirm() {
  local prompt="$1"

  if [[ "$ASSUME_YES" == "1" ]]; then
    log "$prompt: yes"
    return 0
  fi

  if [[ ! -t 0 ]]; then
    warn "$prompt: 입력 가능한 터미널이 없어 거절로 처리합니다. 자동 진행하려면 --yes를 사용하세요."
    return 1
  fi

  local answer
  read -r -p "$prompt [y/N] " answer
  case "$answer" in
    y|Y|yes|YES|Yes) return 0 ;;
    *) return 1 ;;
  esac
}

parse_args() {
  while (($#)); do
    case "$1" in
      -y|--yes)
        ASSUME_YES=1
        shift
        ;;
      --container)
        [[ $# -ge 2 ]] || die "--container 값이 필요합니다."
        CONTAINER_NAME="$2"
        shift 2
        ;;
      --container=*)
        CONTAINER_NAME="${1#*=}"
        shift
        ;;
      --user)
        [[ $# -ge 2 ]] || die "--user 값이 필요합니다."
        CONTAINER_USER="$2"
        shift 2
        ;;
      --user=*)
        CONTAINER_USER="${1#*=}"
        shift
        ;;
      --node-major)
        [[ $# -ge 2 ]] || die "--node-major 값이 필요합니다."
        NODE_MAJOR="$2"
        shift 2
        ;;
      --node-major=*)
        NODE_MAJOR="${1#*=}"
        shift
        ;;
      --package)
        [[ $# -ge 2 ]] || die "--package 값이 필요합니다."
        CODEX_PACKAGE="$2"
        shift 2
        ;;
      --package=*)
        CODEX_PACKAGE="${1#*=}"
        shift
        ;;
      --skip-login)
        SKIP_LOGIN=1
        shift
        ;;
      --direct)
        DIRECT_MODE=1
        shift
        ;;
      --no-compose-volume)
        SKIP_COMPOSE_VOLUME=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "알 수 없는 옵션입니다: $1"
        ;;
    esac
  done
}

docker_cmd() {
  "${DOCKER_CMD[@]}" "$@"
}

compose_cmd() {
  (cd "$SCRIPT_DIR" && "${DOCKER_CMD[@]}" compose "$@")
}

select_docker() {
  command -v docker >/dev/null 2>&1 || return 1

  local output
  if output="$(docker info 2>&1)"; then
    DOCKER_CMD=(docker)
    return 0
  fi

  if printf '%s\n' "$output" | grep -Eiq 'permission denied|Got permission denied|access denied'; then
    if command -v sudo >/dev/null 2>&1 && confirm "현재 사용자로 Docker 접근 권한이 없습니다. sudo로 Docker 명령을 실행할까요?"; then
      sudo -v
      DOCKER_CMD=(sudo docker)
      docker_cmd info >/dev/null 2>&1 || die "sudo로도 Docker에 접근할 수 없습니다."
      return 0
    fi
    die "Docker 접근 권한이 없습니다. Docker 그룹 권한을 설정하거나 sudo 실행을 허용하세요."
  fi

  printf '%s\n' "$output" | sed -n '1,8p' >&2
  die "Docker daemon에 연결할 수 없습니다. Docker가 실행 중인지 확인하세요."
}

container_exists() {
  docker_cmd inspect "$CONTAINER_NAME" >/dev/null 2>&1
}

container_running() {
  [[ "$(docker_cmd inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null || true)" == "true" ]]
}

wait_for_container() {
  local i
  for i in $(seq 1 60); do
    if container_running; then
      return 0
    fi
    sleep 1
  done
  return 1
}

ensure_codex_volume_configured() {
  [[ "$SKIP_COMPOSE_VOLUME" == "0" ]] || return 0
  [[ -f "$COMPOSE_FILE" ]] || return 0

  if grep -Fq '/home/coder/.codex' "$COMPOSE_FILE"; then
    return 0
  fi

  warn "docker-compose.yaml에 /home/coder/.codex 볼륨이 없어 컨테이너 재생성 시 Codex 로그인 정보가 사라질 수 있습니다."
  if ! confirm "docker-compose.yaml에 ./.codex:/home/coder/.codex 볼륨을 추가할까요?"; then
    warn "Codex 로그인 정보 영속화 없이 계속 진행합니다."
    return 0
  fi

  local backup tmp
  backup="$COMPOSE_FILE.bak.$(date +%Y%m%d%H%M%S)"
  tmp="$(mktemp)"
  cp "$COMPOSE_FILE" "$backup"

  if ! awk '
    { print }
    $0 ~ /^[[:space:]]*-[[:space:]]+\.\/\.code-server\/config:\/home\/coder\/\.config[[:space:]]*$/ && inserted == 0 {
      match($0, /^[[:space:]]*/)
      indent = substr($0, RSTART, RLENGTH)
      print indent "- ./.codex:/home/coder/.codex"
      inserted = 1
    }
    END {
      if (inserted == 0) {
        exit 42
      }
    }
  ' "$COMPOSE_FILE" > "$tmp"; then
    rm -f "$tmp"
    warn "볼륨 자동 삽입에 실패했습니다. 백업 파일은 유지됩니다: $backup"
    return 0
  fi

  mv "$tmp" "$COMPOSE_FILE"
  COMPOSE_CHANGED=1
  log "docker-compose.yaml에 .codex 볼륨을 추가했습니다. 백업: $backup"
  compose_cmd config --quiet
}

ensure_container_running() {
  if ! container_exists; then
    [[ -f "$COMPOSE_FILE" ]] || die "컨테이너가 없고 docker-compose.yaml도 찾을 수 없습니다: $COMPOSE_FILE"
    confirm "'$CONTAINER_NAME' 컨테이너가 없습니다. docker compose up -d로 생성할까요?" || die "컨테이너 생성이 취소되었습니다."
    compose_cmd up -d
  elif [[ "$COMPOSE_CHANGED" == "1" ]]; then
    if confirm "볼륨 변경을 반영하려면 컨테이너 재생성이 필요합니다. docker compose up -d --force-recreate를 실행할까요?"; then
      compose_cmd up -d --force-recreate
    else
      warn "현재 실행 중인 컨테이너에는 새 .codex 볼륨이 아직 적용되지 않았을 수 있습니다."
    fi
  elif ! container_running; then
    if [[ -f "$COMPOSE_FILE" ]] && confirm "'$CONTAINER_NAME' 컨테이너가 중지되어 있습니다. docker compose up -d로 시작할까요?"; then
      compose_cmd up -d
    else
      confirm "'$CONTAINER_NAME' 컨테이너를 docker start로 시작할까요?" || die "컨테이너 시작이 취소되었습니다."
      docker_cmd start "$CONTAINER_NAME" >/dev/null
    fi
  fi

  wait_for_container || die "'$CONTAINER_NAME' 컨테이너가 실행 상태가 되지 않았습니다."
}

container_has_mount() {
  local destination="$1"
  docker_cmd inspect -f '{{range .Mounts}}{{println .Destination}}{{end}}' "$CONTAINER_NAME" 2>/dev/null | grep -Fxq "$destination"
}

ensure_codex_mount_active() {
  [[ "$SKIP_COMPOSE_VOLUME" == "0" ]] || return 0
  [[ -f "$COMPOSE_FILE" ]] || return 0
  grep -Fq '/home/coder/.codex' "$COMPOSE_FILE" || return 0

  if container_has_mount '/home/coder/.codex'; then
    return 0
  fi

  warn "현재 실행 중인 '$CONTAINER_NAME' 컨테이너에는 /home/coder/.codex 볼륨이 아직 적용되지 않았습니다."
  if confirm "Codex 로그인 정보 보존을 위해 컨테이너를 재생성할까요?"; then
    compose_cmd up -d --force-recreate
    wait_for_container || die "'$CONTAINER_NAME' 컨테이너가 재생성 후 실행 상태가 되지 않았습니다."
  else
    warn "이번 설치는 계속하지만 Codex 로그인 정보가 컨테이너 재생성 후 사라질 수 있습니다."
  fi
}

container_exec() {
  local user="$1"
  shift
  docker_cmd exec -i -u "$user" "$CONTAINER_NAME" "$@"
}

container_exec_tty() {
  local user="$1"
  shift
  local tty_args=(-i)
  if [[ -t 0 && -t 1 ]]; then
    tty_args=(-it)
  fi
  docker_cmd exec "${tty_args[@]}" -u "$user" "$CONTAINER_NAME" "$@"
}

ensure_container_user() {
  if ! container_exec "$CONTAINER_USER" id >/dev/null 2>&1; then
    die "컨테이너 안에서 '$CONTAINER_USER' 사용자를 찾을 수 없습니다. --user 옵션으로 설치 사용자를 지정하세요."
  fi
}

ensure_container_permissions() {
  if container_exec "$CONTAINER_USER" bash -lc 'mkdir -p "$HOME/.local/bin" "$HOME/.config" "$HOME/.codex" && test -w "$HOME/.local" && test -w "$HOME/.config" && test -w "$HOME/.codex"' >/dev/null 2>&1; then
    return 0
  fi

  confirm "컨테이너 root 권한으로 $CONTAINER_USER 홈의 .local/.config/.codex 소유권을 정리할까요?" || die "필요한 사용자 디렉터리 권한을 확보하지 못했습니다."
  container_exec root bash -s -- "$CONTAINER_USER" <<'EOF'
set -Eeuo pipefail
target_user="$1"
target_home="$(getent passwd "$target_user" | cut -d: -f6)"
target_uid="$(id -u "$target_user")"
target_gid="$(id -g "$target_user")"

mkdir -p "$target_home/.local/bin" "$target_home/.config" "$target_home/.codex"
chown -R "$target_uid:$target_gid" "$target_home/.local" "$target_home/.config" "$target_home/.codex"
EOF
}

container_node_status() {
  container_exec "$CONTAINER_USER" bash -lc 'set -Eeuo pipefail; command -v node >/dev/null; command -v npm >/dev/null; node -p "process.versions.node.split(\".\")[0]"; node -v; npm -v'
}

install_node_in_container() {
  confirm "컨테이너 root 권한으로 Node.js ${NODE_MAJOR}.x와 npm을 설치/갱신할까요?" || die "Node.js/npm 설치가 취소되었습니다."
  container_exec root bash -s -- "$NODE_MAJOR" <<'EOF'
set -Eeuo pipefail
node_major="$1"
export DEBIAN_FRONTEND=noninteractive

command -v apt-get >/dev/null 2>&1 || {
  echo "apt-get을 찾을 수 없습니다. Debian/Ubuntu 계열 컨테이너만 자동 설치를 지원합니다." >&2
  exit 1
}

apt-get update
apt-get install -y curl ca-certificates
curl -fsSL "https://deb.nodesource.com/setup_${node_major}.x" | bash -
apt-get install -y nodejs
node -v
npm -v
EOF
}

ensure_node_in_container() {
  local status current_major node_version npm_version
  if status="$(container_node_status 2>/dev/null)"; then
    current_major="$(printf '%s\n' "$status" | sed -n '1p')"
    node_version="$(printf '%s\n' "$status" | sed -n '2p')"
    npm_version="$(printf '%s\n' "$status" | sed -n '3p')"
    log "현재 Node.js: $node_version, npm: $npm_version"

    if [[ "$current_major" == "$NODE_MAJOR" ]]; then
      return 0
    fi

    warn "권장 Node.js 메이저 버전은 ${NODE_MAJOR}.x이지만 현재는 ${node_version}입니다."
    if confirm "Node.js ${NODE_MAJOR}.x로 설치/갱신하고 계속할까요?"; then
      install_node_in_container
    else
      warn "현재 Node.js 버전으로 Codex CLI 설치를 계속합니다."
    fi
    return 0
  fi

  warn "컨테이너 안에서 Node.js 또는 npm을 찾을 수 없습니다."
  install_node_in_container
}

install_codex_in_container() {
  log "npm 전역 prefix를 사용자 홈으로 설정하고 $CODEX_PACKAGE 패키지를 설치합니다."
  container_exec "$CONTAINER_USER" bash -s -- "$CODEX_PACKAGE" <<'EOF'
set -Eeuo pipefail
package_name="$1"
profile_line='export PATH="$HOME/.local/bin:$PATH"'

mkdir -p "$HOME/.local/bin"
npm config set prefix "$HOME/.local"

for profile in "$HOME/.bashrc" "$HOME/.profile"; do
  touch "$profile"
  if ! grep -Fqx "$profile_line" "$profile"; then
    printf '\n%s\n' "$profile_line" >> "$profile"
  fi
done

export PATH="$HOME/.local/bin:$PATH"
npm install -g "$package_name"
command -v codex
codex --version
EOF
}

verify_codex_in_container() {
  log "Codex CLI 설치 상태를 확인합니다."
  container_exec "$CONTAINER_USER" bash -lc 'set -Eeuo pipefail; export PATH="$HOME/.local/bin:$PATH"; command -v codex; codex --version'
}

login_codex_in_container() {
  [[ "$SKIP_LOGIN" == "0" ]] || return 0

  if confirm "Codex device auth 로그인을 지금 시작할까요?"; then
    if ! container_exec_tty "$CONTAINER_USER" bash -lc 'export PATH="$HOME/.local/bin:$PATH"; codex login --device-auth && codex login status'; then
      warn "Codex 로그인이 완료되지 않았습니다. 나중에 컨테이너 안에서 codex login --device-auth를 다시 실행하세요."
    fi
  else
    cat <<EOF

나중에 로그인하려면 아래 명령을 실행하세요.

docker exec -it -u $CONTAINER_USER $CONTAINER_NAME bash -lc 'export PATH="\$HOME/.local/bin:\$PATH"; codex login --device-auth'
EOF
  fi
}

host_install() {
  select_docker || die "Docker CLI를 찾을 수 없습니다. 컨테이너 안에서 직접 실행하려면 --direct 옵션을 사용하세요."

  mkdir -p "$SCRIPT_DIR/.code-server/local" "$SCRIPT_DIR/.code-server/config" "$SCRIPT_DIR/workspace" "$SCRIPT_DIR/.codex"
  ensure_codex_volume_configured
  ensure_container_running
  ensure_codex_mount_active
  ensure_container_user
  ensure_container_permissions
  ensure_node_in_container
  install_codex_in_container
  verify_codex_in_container
  login_codex_in_container
}

direct_node_status() {
  bash -lc 'set -Eeuo pipefail; command -v node >/dev/null; command -v npm >/dev/null; node -p "process.versions.node.split(\".\")[0]"; node -v; npm -v'
}

install_node_direct() {
  command -v apt-get >/dev/null 2>&1 || die "apt-get을 찾을 수 없습니다. 직접 설치 모드는 Debian/Ubuntu 계열 환경만 자동 설치를 지원합니다."

  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    log "root 권한으로 Node.js ${NODE_MAJOR}.x를 설치합니다."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y curl ca-certificates
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    apt-get install -y nodejs
    node -v
    npm -v
    return 0
  fi

  command -v sudo >/dev/null 2>&1 || die "Node.js/npm 설치에 root 권한이 필요하지만 sudo를 찾을 수 없습니다. 호스트에서 ./install.sh를 실행하거나 root로 다시 실행하세요."
  confirm "sudo 권한으로 Node.js ${NODE_MAJOR}.x와 npm을 설치/갱신할까요?" || die "Node.js/npm 설치가 취소되었습니다."
  sudo -v
  sudo apt-get update
  sudo apt-get install -y curl ca-certificates
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | sudo -E bash -
  sudo apt-get install -y nodejs
  node -v
  npm -v
}

ensure_node_direct() {
  local status current_major node_version npm_version
  if status="$(direct_node_status 2>/dev/null)"; then
    current_major="$(printf '%s\n' "$status" | sed -n '1p')"
    node_version="$(printf '%s\n' "$status" | sed -n '2p')"
    npm_version="$(printf '%s\n' "$status" | sed -n '3p')"
    log "현재 Node.js: $node_version, npm: $npm_version"

    if [[ "$current_major" == "$NODE_MAJOR" ]]; then
      return 0
    fi

    warn "권장 Node.js 메이저 버전은 ${NODE_MAJOR}.x이지만 현재는 ${node_version}입니다."
    if confirm "Node.js ${NODE_MAJOR}.x로 설치/갱신하고 계속할까요?"; then
      install_node_direct
    else
      warn "현재 Node.js 버전으로 Codex CLI 설치를 계속합니다."
    fi
    return 0
  fi

  warn "Node.js 또는 npm을 찾을 수 없습니다."
  install_node_direct
}

install_codex_direct() {
  log "npm 전역 prefix를 사용자 홈으로 설정하고 $CODEX_PACKAGE 패키지를 설치합니다."
  mkdir -p "$HOME/.local/bin"
  npm config set prefix "$HOME/.local"

  local profile profile_line
  profile_line='export PATH="$HOME/.local/bin:$PATH"'
  for profile in "$HOME/.bashrc" "$HOME/.profile"; do
    touch "$profile"
    if ! grep -Fqx "$profile_line" "$profile"; then
      printf '\n%s\n' "$profile_line" >> "$profile"
    fi
  done

  export PATH="$HOME/.local/bin:$PATH"
  npm install -g "$CODEX_PACKAGE"
  command -v codex
  codex --version
}

login_codex_direct() {
  [[ "$SKIP_LOGIN" == "0" ]] || return 0

  if confirm "Codex device auth 로그인을 지금 시작할까요?"; then
    if ! codex login --device-auth; then
      warn "Codex 로그인이 완료되지 않았습니다. 나중에 codex login --device-auth를 다시 실행하세요."
    fi
  else
    cat <<'EOF'

나중에 로그인하려면 아래 명령을 실행하세요.

export PATH="$HOME/.local/bin:$PATH"
codex login --device-auth
EOF
  fi
}

direct_install() {
  ensure_node_direct
  install_codex_direct
  login_codex_direct
}

main() {
  parse_args "$@"

  log "대상 Codex CLI 패키지: $CODEX_PACKAGE"
  log "권장 Node.js 버전: ${NODE_MAJOR}.x"

  if [[ "$DIRECT_MODE" == "1" ]]; then
    direct_install
  else
    host_install
  fi

  log "설치 흐름이 끝났습니다."
}

main "$@"
