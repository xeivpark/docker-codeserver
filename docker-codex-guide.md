# Docker code-server 안에서 Codex CLI 사용 가이드

이 문서는 `code-server` Docker 컨테이너 안에서 Codex CLI를 설치하고 로그인하는 절차를 정리한 가이드입니다.

현재 대상 컨테이너:

- 컨테이너 이름: `code-server`
- 작업 디렉터리: `/home/coder/project`
- 현재 사용자: `coder`
- 홈 디렉터리: `/home/coder`
- 권장 Codex CLI 패키지: `@openai/codex`

## 자동 설치 스크립트

호스트의 `github-shared` 디렉터리에서 아래 스크립트를 실행하면 이 문서의 설치 과정을 자동으로 수행합니다.

```bash
./install.sh
```

스크립트는 다음을 확인한 뒤 진행합니다.

- `code-server` 컨테이너 실행 여부
- Node.js/npm 설치 여부
- 사용자 홈 npm 전역 설치 경로 권한
- Codex CLI 설치 여부
- 필요 시 컨테이너 root 권한으로 Node.js 설치 및 권한 정리

확인 질문 없이 진행하려면:

```bash
./install.sh --yes
```

설치만 하고 로그인은 나중에 하려면:

```bash
./install.sh --skip-login
```

컨테이너 내부에서 직접 실행해야 한다면:

```bash
./install.sh --direct
```

## 1. 터미널 접속

브라우저에서 code-server를 열었다면 VS Code 터미널을 그대로 사용하면 됩니다.

호스트 터미널에서 직접 컨테이너에 들어가려면:

```bash
docker exec -it code-server bash
```

root 권한으로 들어가야 할 때:

```bash
docker exec -it -u root code-server bash
```

현재 위치와 사용자를 확인합니다.

```bash
whoami
pwd
echo "$HOME"
```

## 2. Node.js와 npm 확인

먼저 이미 설치되어 있는지 확인합니다.

```bash
node -v
npm -v
```

현재 컨테이너에는 Node.js 22 계열과 npm이 설치되어 있으면 Codex CLI 설치로 바로 넘어가면 됩니다.

Node.js가 없을 때만 설치합니다.

## 3. Node.js 설치가 필요할 때

일반 사용자 터미널에서 설치할 경우 아래처럼 실행합니다.

```bash
sudo apt-get update
sudo apt-get install -y curl ca-certificates
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs
node -v
npm -v
```

주의할 점:

```bash
sudo curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
```

위 방식은 권장하지 않습니다. `sudo`가 `curl`에만 적용되고 파이프 뒤의 `bash -`는 일반 사용자 권한으로 실행되어 `apt update` 권한 오류가 날 수 있습니다.

올바른 형태는 아래입니다.

```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
```

`sudo`가 없거나 권한 문제가 계속 나면 호스트에서 root로 컨테이너에 들어간 뒤 실행합니다.

```bash
docker exec -it -u root code-server bash
```

컨테이너 안에서:

```bash
apt-get update
apt-get install -y curl ca-certificates
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs
node -v
npm -v
```

## 4. Codex CLI 설치

Codex CLI 패키지는 `openai`가 아니라 `@openai/codex`입니다.

권장 방식은 사용자 홈 아래에 npm 전역 설치 경로를 잡는 것입니다. 이렇게 하면 `/usr/lib/node_modules` 권한 오류를 피할 수 있습니다.

```bash
mkdir -p "$HOME/.local"
npm config set prefix "$HOME/.local"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
export PATH="$HOME/.local/bin:$PATH"

npm install -g @openai/codex
codex --version
```

정상 예시:

```text
codex-cli 0.134.0
```

이미 root 권한으로 전역 설치되어 있다면 아래 명령으로 위치를 확인합니다.

```bash
command -v codex
codex --version
```

## 5. npm EACCES 오류 해결

아래 오류는 일반 사용자가 `/usr/lib/node_modules`에 쓸 권한이 없어서 발생합니다.

```text
npm error code EACCES
npm error path /usr/lib/node_modules/...
```

해결 방법은 npm 전역 설치 경로를 사용자 홈으로 바꾸는 것입니다.

```bash
mkdir -p "$HOME/.local"
npm config set prefix "$HOME/.local"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
export PATH="$HOME/.local/bin:$PATH"
npm install -g @openai/codex
```

임시로 `sudo npm install -g @openai/codex`를 사용할 수도 있지만 권장하지 않습니다. 컨테이너 재생성, 권한 꼬임, 업데이트 관리 측면에서 사용자 홈 설치가 더 안정적입니다.

## 6. 로그인 방법

Docker 안에서는 기본 로그인 방식보다 device auth 방식이 적합합니다.

```bash
codex login --device-auth
```

명령을 실행하면 URL과 인증 코드가 표시됩니다. URL을 브라우저에서 열고 표시된 코드를 입력하면 됩니다.

기본 로그인 방식은 아래처럼 실행합니다.

```bash
codex login
```

하지만 Docker 또는 원격 code-server 안에서는 인증 콜백이 `http://localhost:1455/auth/callback` 형태로 열릴 수 있습니다. 이때 브라우저의 `localhost`는 컨테이너가 아니라 사용자의 PC를 가리키므로 인증이 실패할 수 있습니다.

따라서 Docker/code-server 환경에서는 아래를 우선 사용합니다.

```bash
codex login --device-auth
```

API 키로 로그인해야 한다면:

```bash
read -s OPENAI_API_KEY
printf '%s' "$OPENAI_API_KEY" | codex login --with-api-key
codex login status
```

환경 변수 방식으로 실행할 수도 있습니다.

```bash
export OPENAI_API_KEY="여기에_API_KEY"
codex
```

단, API 키를 셸 히스토리나 문서에 남기지 않도록 주의합니다.

## 7. 로그인 상태 확인

```bash
codex login status
```

Codex 실행:

```bash
codex
```

특정 프로젝트 폴더에서 실행:

```bash
cd /home/coder/project/01_proj
codex
```

## 8. 컨테이너 재생성 시 유지 문제

현재 `docker-compose.yaml`은 다음 경로를 볼륨으로 유지합니다.

```yaml
volumes:
  - ./.code-server/local:/home/coder/.local
  - ./.code-server/config:/home/coder/.config
  - ./.codex:/home/coder/.codex
  - ./workspace:/home/coder/project
```

사용자 홈 npm 전역 설치 경로를 `$HOME/.local`로 설정하면 Codex CLI 바이너리는 재생성 후에도 유지됩니다. Codex 로그인 정보는 `$HOME/.codex` 아래에 저장될 수 있으므로, 이 경로도 볼륨으로 유지합니다.

볼륨 구성을 변경한 뒤에는 컨테이너를 재생성합니다.

```bash
docker compose up -d --force-recreate
```

주의: `.codex`에는 인증 정보가 포함될 수 있으므로 외부 저장소에 올리지 않습니다.

## 9. 자주 나는 오류

### apt lock permission denied

증상:

```text
Could not open lock file /var/lib/apt/lists/lock - open (13: Permission denied)
Unable to lock directory /var/lib/apt/lists/
```

원인:

- `apt update`가 일반 사용자 권한으로 실행되었습니다.
- `sudo curl ... | bash -`처럼 파이프 뒤 명령에 sudo가 적용되지 않았습니다.

해결:

```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs
```

또는 root로 컨테이너 접속:

```bash
docker exec -it -u root code-server bash
```

### npm EACCES

증상:

```text
EACCES: permission denied, mkdir '/usr/lib/node_modules/...'
```

해결:

```bash
mkdir -p "$HOME/.local"
npm config set prefix "$HOME/.local"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
export PATH="$HOME/.local/bin:$PATH"
npm install -g @openai/codex
```

### localhost:1455 인증 실패

증상:

```text
http://localhost:1455/auth/callback
```

브라우저에서 인증 후 localhost 콜백이 열리지 않거나 연결 실패가 납니다.

원인:

- Codex CLI는 컨테이너 안에서 `localhost:1455`를 기다립니다.
- 브라우저의 `localhost`는 컨테이너가 아니라 사용자의 PC입니다.

해결:

```bash
codex login --device-auth
```

## 10. 권장 설치 순서 요약

code-server 터미널에서 아래 순서로 실행합니다.

```bash
node -v
npm -v

mkdir -p "$HOME/.local"
npm config set prefix "$HOME/.local"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
export PATH="$HOME/.local/bin:$PATH"

npm install -g @openai/codex
codex --version
codex login --device-auth
codex login status
```

## 참고 링크

```text
https://platform.openai.com/docs/guides/code-generation
https://platform.openai.com/docs/docs-mcp
```
