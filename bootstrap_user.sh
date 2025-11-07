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

# known_hosts 사전 등록(파일 보장 + ssh-keyscan 있으면만 등록)
touch "$SSH_DIR/known_hosts"
if command -v ssh-keyscan >/dev/null 2>&1; then
  if ! ssh-keygen -F github.com >/dev/null; then
    ssh-keyscan github.com >> "$SSH_DIR/known_hosts" 2>/dev/null || true
  fi
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


# GitHub SSH 인증
prompt_manual_github_key() {
  echo
  echo "======= GitHub SSH key setup check ======="
  echo

  # --- 1회 인증 시도 ---
  set +e
  out="$(ssh -o BatchMode=yes -o IdentitiesOnly=yes -i "$SSH_DIR/id_ed25519" -T git@github.com 2>&1)"
  rc=$?
  set -e
  if echo "$out" | grep -qi "you've successfully authenticated"; then
    echo "[=] 이미 GitHub SSH 인증이 완료되어 있음 ✅"
    echo "$out"
    return 0
  fi
  
  # --- 인증 안 된 경우 수동 등록 안내 ---
  echo "[!] GitHub SSH 인증되지 않음 — 수동 등록 필요"
  echo
  echo "1) 아래 공개키 내용을 복사"
  echo "   (파일: $SSH_DIR/id_ed25519.pub)"
  echo
  echo "----------------------------------------------------------------"
  cat "$SSH_DIR/id_ed25519.pub"
  echo "----------------------------------------------------------------"
  echo
  echo "2) 브라우저로 열기 → GitHub Settings > SSH and GPG keys > New SSH key"
  echo "   링크: https://github.com/settings/keys"
  echo
  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "https://github.com/settings/keys" >/dev/null 2>&1 || true
  fi

  while true; do
    read -r -p "[?] 키 등록 완료면 Enter, 건너뛰려면 'skip' 입력: " ans
    if [ "${ans:-}" = "skip" ]; then
      echo "[=] 수동 등록 건너뜀"
      break
    fi

    set +e
    out="$(ssh -o BatchMode=yes -o IdentitiesOnly=yes -i "$SSH_DIR/id_ed25519" -T git@github.com 2>&1)"
    rc=$?
    set -e
    echo "$out"

    if echo "$out" | grep -qi "you've successfully authenticated"; then
      echo "[+] GitHub SSH 인증 확인 완료 ✅"
      break
    else
      echo "[!] 아직 인증되지 않음. GitHub 페이지에서 'Add SSH key' 저장 후 다시 Enter"
      echo "    링크: https://github.com/settings/keys"
      sleep 1
    fi
  done
  echo
}

prompt_manual_github_key

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
