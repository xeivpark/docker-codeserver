# code-server Docker 운영 가이드

이 폴더는 Docker로 `code-server`를 실행하고 외부 도메인으로 접속하기 위한 설정입니다.

현재 기본 구성은 다음과 같습니다.

- 컨테이너 이미지: `ghcr.io/coder/code-server:4.121.0`
- 내부 포트: `8080`
- 호스트 공개 포트: `.env`의 `CODE_SERVER_PORT`, 기본값 `12345`
- 로컬 접속: `http://127.0.0.1:12345`
- 외부 도메인 접속 예시: `https://code.example.com`

## 실행

공유용 저장소에는 실제 `.env`를 포함하지 않습니다. 먼저 예시 파일을 복사한 뒤 환경에 맞게 값을 조정합니다.

```bash
cp .env.example .env
```

```bash
docker compose up -d
```

상태 확인:

```bash
docker compose ps
docker logs --tail=120 code-server
```

종료:

```bash
docker compose down
```

## 접속 주소

로컬에서 직접 확인:

```text
http://127.0.0.1:12345
```

외부에서는 Cloudflare 또는 reverse proxy를 통과한 표준 HTTPS 주소로 접속합니다.

```text
https://code.example.com
```

외부에서 아래 주소는 사용하지 않습니다.

```text
http://code.example.com:12345
```

Cloudflare proxy 기본 지원 포트에 `12345`가 포함되지 않기 때문에, Cloudflare를 켠 상태에서는 `:12345` 직접 접속이 타임아웃될 수 있습니다. 외부 공개는 `443` HTTPS 도메인으로 받고, 내부에서 `127.0.0.1:12345` 또는 컨테이너 `8080`으로 프록시해야 합니다.

Cloudflare 지원 포트 문서:

```text
https://developers.cloudflare.com/fundamentals/reference/network-ports/
```

## 1006 WebSocket 오류

외부 도메인 접속 후 아래 오류가 보이면 HTTP 페이지는 열렸지만 code-server workbench의 WebSocket 연결이 끊긴 상태입니다.

```text
An unexpected error occurred that requires a reload of this page.
The workbench failed to connect to the server (Error: WebSocket close with status code 1006)
```

code-server는 브라우저와 서버 사이 통신에 WebSocket을 필수로 사용합니다. 따라서 중간의 Cloudflare, Nginx, Caddy, 공유기 프록시, WAF, 브라우저 캐시 중 하나가 WebSocket Upgrade 요청을 막으면 로그인 이후 workbench가 실패합니다.

## 확인 명령

컨테이너가 정상인지 확인:

```bash
docker compose ps
```

로컬 HTTP 확인:

```bash
curl -I http://127.0.0.1:12345
```

code-server 헬스체크:

```bash
curl -sS http://127.0.0.1:12345/healthz
curl -sS https://code.example.com/healthz
```

정상 응답 예시:

```json
{"status":"alive","lastHeartbeat":1779864061767}
```

외부 도메인이 Cloudflare로 향하는지 확인:

```bash
dig +short code.example.com
```

## Cloudflare 설정 체크리스트

Cloudflare를 사용하는 경우 다음을 확인합니다.

1. `Network > WebSockets`가 `On`인지 확인합니다.
2. `code.example.com/*`에 대해 캐시 우회 규칙을 적용합니다.
3. Rocket Loader, Auto Minify 등 JS 변형 기능을 이 호스트에는 적용하지 않습니다.
4. WAF, Bot Fight Mode, Rate Limiting, Cloudflare Access 정책이 WebSocket Upgrade 요청을 차단하지 않는지 확인합니다.
5. 외부 접속은 `https://code.example.com`만 사용하고 `:12345` 포트는 붙이지 않습니다.

Cloudflare WebSocket 문서:

```text
https://developers.cloudflare.com/network/websockets/
```

## Nginx reverse proxy 예시

Nginx를 앞단에 두는 경우 WebSocket 헤더를 반드시 전달해야 합니다.

```nginx
server {
  listen 80;
  server_name code.example.com;

  location / {
    proxy_pass http://127.0.0.1:12345;
    proxy_http_version 1.1;
    proxy_set_header Host $http_host;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Accept-Encoding gzip;
    proxy_read_timeout 86400;
  }
}
```

TLS를 Nginx에서 직접 종료한다면 `listen 443 ssl;`과 인증서 설정을 추가합니다. Cloudflare에서 TLS를 종료하고 원본 서버로 HTTP를 전달하는 구조라면 Cloudflare SSL/TLS 모드와 원본 프록시 설정이 서로 맞아야 합니다.

code-server 공식 reverse proxy 문서:

```text
https://coder.com/docs/code-server/guide
```

## Caddy reverse proxy 예시

Caddy를 사용하는 경우 기본 reverse proxy 설정만으로 WebSocket이 전달됩니다.

```caddyfile
code.example.com {
  reverse_proxy 127.0.0.1:12345
}
```

## Docker 설정

`docker-compose.yaml`은 `.env` 값을 사용해 code-server를 실행합니다. GitHub 공유용에는 `.env.example`만 포함되어 있으므로 실제 운영 전 `.env`를 직접 생성합니다.

주요 환경 변수:

```env
CODE_SERVER_IMAGE=ghcr.io/coder/code-server:4.121.0
CODE_SERVER_HOST=0.0.0.0
CODE_SERVER_PORT=12345
CODE_SERVER_PASSWORD=...
HOST_UID=1000
HOST_GID=1000
DOCKER_USER=coder
TZ=Asia/Seoul
```

외부 접속을 허용하려면 `CODE_SERVER_HOST=0.0.0.0`이어야 합니다. 로컬에서만 접근하려면 `127.0.0.1`로 제한할 수 있습니다.

## 보안 주의

code-server는 개발 환경 전체에 접근할 수 있으므로 공개 인터넷에 직접 노출하지 않는 편이 좋습니다.

권장 사항:

- `CODE_SERVER_PASSWORD`는 강한 값으로 교체합니다.
- `.env` 파일을 외부 저장소에 올리지 않습니다.
- 가능하면 Cloudflare Access, VPN, SSH 터널, Cloudflare Tunnel 중 하나로 접근 제어를 추가합니다.
- `12345` 포트를 인터넷에 직접 열기보다 `443` reverse proxy 뒤에서 운영합니다.

비밀번호를 바꾼 뒤에는 컨테이너를 재시작합니다.

```bash
docker compose up -d --force-recreate
```

## 장애 대응 순서

1. 컨테이너 상태를 확인합니다.

```bash
docker compose ps
```

2. 로컬에서 code-server가 응답하는지 확인합니다.

```bash
curl -I http://127.0.0.1:12345
curl -sS http://127.0.0.1:12345/healthz
```

3. 도메인에서 헬스체크가 되는지 확인합니다.

```bash
curl -sS https://code.example.com/healthz
```

4. 브라우저의 `code.example.com` 사이트 데이터와 쿠키를 삭제한 뒤 새 시크릿 창에서 다시 접속합니다.

5. Cloudflare의 WebSockets, WAF, Cache Rule, Access 정책을 확인합니다.

6. Nginx 또는 Caddy를 사용한다면 WebSocket Upgrade 헤더가 전달되는지 확인합니다.

## 현재 확인된 원인 정리

`https://code.example.com`에서 로그인 페이지와 `/healthz`가 정상이라면 도메인 라우팅과 컨테이너는 살아 있는 상태입니다. 이때 workbench에서만 `WebSocket close with status code 1006`이 발생하면 원인은 대부분 WebSocket Upgrade 요청 차단, 프록시 헤더 누락, Cloudflare 정책, 브라우저 캐시 또는 쿠키 충돌입니다.

`http://code.example.com:12345`가 타임아웃되는 것은 Cloudflare proxy 포트 제한 때문에 발생할 수 있으며, 정상 운영 주소는 `https://code.example.com`입니다.
