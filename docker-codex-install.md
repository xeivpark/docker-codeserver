
# 요약편 (수동 작성)

## 터미널 접속
호스트 터미널에서 직접 컨테이너에 들어가려면:

```bash
docker exec -it code-server bash
```

# 터미널 접속 후 아래 명령어 수동으로 1줄씩 입력 수행 
whoami

# nodejs, npm - install 
sudo apt install -y curl
sudo curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
sudo apt install -y nodejs

# openai cli 설치
sudo npm install -g @openai/codex
codex --version

# codex login 1 : web으로연결하는 방법, docker 에서는 사용 불가  (login 2 방법 사용 할 것)
codex login

# codex login 2 : 디바이스 로그인 방법, docker에서 사용 가능 
codex login --device-auth 

그러면 인증 코드와 URL이 나올 겁니다. URL은 브라우저에서 열고, 표시된 코드를 입력하면 됩니다. 
이 방식은 localhost:1455 콜백을 쓰지 않아서 Docker/code-server 환경에 적합합니다.




