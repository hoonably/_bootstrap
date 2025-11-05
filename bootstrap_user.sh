#!/usr/bin/env bash
set -euo pipefail

echo "=== [BOOTSTRAP_USER] 시작 ==="

# 리포 루트와 setting 디렉토리 계산
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS_DIR="${REPO_DIR}/setting"

# setting 폴더 존재 확인
if [ ! -d "$SETTINGS_DIR" ]; then
  echo "[!] setting 디렉토리를 찾을 수 없음: $SETTINGS_DIR"
  exit 1
fi

SSH_DIR="$HOME/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# known_hosts 사전 등록
if ! ssh-keygen -F github.com >/dev/null; then
  ssh-keyscan github.com >> "$SSH_DIR/known_hosts" 2>/dev/null || true
fi
chmod 600 "$SSH_DIR/known_hosts" || true

# SSH 키 생성(없을 때만)
if [ ! -f "$SSH_DIR/id_ed25519" ]; then
  ssh-keygen -t ed25519 -N "" -f "$SSH_DIR/id_ed25519" -C "$HOSTNAME-$(date +%F)"
  echo "[+] SSH key created: $SSH_DIR/id_ed25519"
else
  echo "[=] Reusing SSH key: $SSH_DIR/id_ed25519"
fi

# .ssh/config 자동 생성
cat > "$SSH_DIR/config" <<EOF
Host github.com
  HostName github.com
  User git
  IdentityFile ${SSH_DIR}/id_ed25519
  IdentitiesOnly yes
EOF
chmod 600 "$SSH_DIR/config"
echo "[+] .ssh/config ready"

# GitHub 공개키 자동 업로드 (GITHUB_TOKEN 있으면)
if command -v curl >/dev/null 2>&1 && [ -n "${GITHUB_TOKEN:-}" ]; then
  PUB_KEY="$(cat "$SSH_DIR/id_ed25519.pub")"
  TITLE="${HOSTNAME}-$(date +%F)"
  RESP_CODE=$(
    curl -s -o /dev/null -w "%{http_code}" \
      -H "Authorization: token $GITHUB_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      -d "{\"title\":\"$TITLE\",\"key\":\"$PUB_KEY\"}" \
      https://api.github.com/user/keys
  )
  if [ "$RESP_CODE" = "201" ] || [ "$RESP_CODE" = "422" ]; then
    echo "[+] GitHub SSH key registered or already exists ($RESP_CODE)"
  else
    echo "[!] GitHub SSH key registration failed (HTTP $RESP_CODE)"
  fi
else
  echo "[=] Skip GitHub key upload (curl or GITHUB_TOKEN missing)"
fi

# 연결 테스트는 실패해도 진행
ssh -T git@github.com || true

# .gitconfig 자동 생성 (기존 있으면 1회 백업)
GITCONFIG_PATH="$HOME/.gitconfig"
if [ -f "$GITCONFIG_PATH" ] && [ ! -f "$GITCONFIG_PATH.bak" ]; then
  cp -f "$GITCONFIG_PATH" "$GITCONFIG_PATH.bak" || true
  echo "[=] Existing .gitconfig backed up to .gitconfig.bak"
fi
cat > "$GITCONFIG_PATH" <<EOF
[user]
  name = Jeonghoon Park
  email = hoonably@gmail.com
[init]
  defaultBranch = main
[pull]
  ff = only
[core]
  # editor = vim
  excludesfile = ${SETTINGS_DIR}/gitignore_global
[filter "lfs"]
  smudge = git-lfs smudge -- %f
  process = git-lfs filter-process
  required = true
  clean = git-lfs clean -- %f
EOF
chmod 600 "$GITCONFIG_PATH"
echo "[+] .gitconfig ready"

# env.sh 연결(존재 시에만, 중복 방지)
if [ -f "${SETTINGS_DIR}/env.sh" ]; then
  if ! grep -qxF "source ${SETTINGS_DIR}/env.sh" ~/.bashrc 2>/dev/null; then
    echo "source ${SETTINGS_DIR}/env.sh" >> ~/.bashrc
    echo "[+] env.sh linked in .bashrc"
  else
    echo "[=] env.sh already linked"
  fi
else
  echo "[=] env.sh not found, skip linking"
fi

# tmux/vim 설정 링크(존재 시)
[ -f "${SETTINGS_DIR}/tmux.conf" ] && ln -sf "${SETTINGS_DIR}/tmux.conf" ~/.tmux.conf
[ -f "${SETTINGS_DIR}/vimrc" ] && ln -sf "${SETTINGS_DIR}/vimrc" ~/.vimrc

# 적용
# shellcheck disable=SC1090
source ~/.bashrc || true

echo "[OK] ✅ BOOTSTRAP_USER finished"
