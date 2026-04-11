#!/usr/bin/env bash
set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 실패 추적 배열
FAILURES=()
GIT_IDENTITY_SETUP_ENABLED=true

# ============================================================
# 환경 감지 (K8s vs SSH)
# ============================================================
IS_K8S=false
if [ -n "${KUBERNETES_SERVICE_HOST:-}" ] || [ -f /var/run/secrets/kubernetes.io/serviceaccount/token ]; then
  IS_K8S=true
  echo "[*] 쿠버네티스 환경 감지됨"
else
  echo "[*] 일반 SSH 환경 감지됨"
fi

# ============================================================
# 1. Miniconda 설치
# ============================================================
echo ""
echo "======= Miniconda 설치 ======="
echo ""

CONDA_INSTALLED=false

if command -v conda >/dev/null 2>&1; then
  echo "[=] Conda 이미 설치됨: $(command -v conda)"

  # ~/.bashrc에 conda initialize가 없고, 설치 위치를 찾을 수 있으면 init
  if ! grep -q 'conda initialize' ~/.bashrc 2>/dev/null; then
    CONDA_BASE="$(conda info --base 2>/dev/null || true)"
    if [ -n "${CONDA_BASE:-}" ] && [ -f "$CONDA_BASE/bin/conda" ]; then
      "$CONDA_BASE/bin/conda" init bash 2>/dev/null || true
      echo "[+] conda init 완료"
    fi
  fi

  CONDA_INSTALLED=true

elif [ -d "$HOME/miniconda3" ]; then
  echo "[=] Miniconda 디렉토리 존재: $HOME/miniconda3"

  if ! grep -q 'conda initialize' ~/.bashrc 2>/dev/null; then
    if [ -f "$HOME/miniconda3/bin/conda" ]; then
      "$HOME/miniconda3/bin/conda" init bash 2>/dev/null || true
      echo "[+] conda init 완료"
    fi
  fi

  CONDA_INSTALLED=true

else
  echo "[*] Miniconda 설치 중..."
  if wget -q https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O "$HOME/miniconda.sh" 2>/dev/null; then
    if ! bash "$HOME/miniconda.sh" -b -p "$HOME/miniconda3" 2>/dev/null; then
      FAILURES+=("Miniconda 설치")
    fi
    rm -f "$HOME/miniconda.sh"

    if [ -f "$HOME/miniconda3/bin/conda" ]; then
      if ! grep -q 'conda initialize' ~/.bashrc 2>/dev/null; then
        "$HOME/miniconda3/bin/conda" init bash 2>/dev/null || true
      fi
      echo "[+] Miniconda 설치 완료"
      CONDA_INSTALLED=true
    fi
  else
    FAILURES+=("Miniconda 다운로드")
  fi
fi

# 현재 shell에서 conda 사용 가능하도록 초기화
if [ "$CONDA_INSTALLED" = true ]; then
  CONDA_BASE="$(conda info --base 2>/dev/null || true)"
  if [ -n "${CONDA_BASE:-}" ] && [ -f "$CONDA_BASE/etc/profile.d/conda.sh" ]; then
    source "$CONDA_BASE/etc/profile.d/conda.sh"
    conda activate base 2>/dev/null || true
    conda config --set changeps1 false 2>/dev/null || true
    echo "[+] 현재 shell에서 conda 활성화 완료"
  fi
fi

# ============================================================
# 2. GitHub 인증 설정 및 확인
# ============================================================
echo ""
if [ "$IS_K8S" = true ]; then
  echo "======= GitHub 인증 설정 (K8s: HTTPS Token 방식) ======="
  echo ""

  CRED_FILE="$HOME/.git-credentials"
  GITHUB_AUTH_OK=false

  # 1. 이미 저장된 credential이 있으면 우선 재사용
  if [ -f "$CRED_FILE" ] && grep -q "github.com" "$CRED_FILE" 2>/dev/null; then
    echo "[=] 기존 ~/.git-credentials에서 GitHub 인증 정보 발견"
    git config --global credential.helper store
    GITHUB_AUTH_OK=true
  fi

  # 2. 저장된 credential이 없고, 환경변수도 없으면 입력받기
  if [ "$GITHUB_AUTH_OK" = false ] && [ -z "${GITHUB_TOKEN:-}" ]; then
    echo "[!] 쿠버네티스 환경에서는 GitHub Personal Access Token(PAT)이 필요합니다."
    echo ""
    echo "다음 페이지에서 토큰을 발급하세요:"
    echo "  https://github.com/settings/personal-access-tokens"
    echo ""
    echo "권장 권한:"
    echo "  - Contents: Read and write"
    echo "  - Metadata: Read"
    echo ""
    read -r -s -p "GITHUB_TOKEN을 붙여넣고 Enter (건너뛰려면 그냥 Enter): " GITHUB_TOKEN
    echo ""

    if [ -n "${GITHUB_TOKEN:-}" ]; then
      export GITHUB_TOKEN
      echo "[+] GITHUB_TOKEN 입력 완료"
    fi
  fi

  # 3. 환경변수로 토큰이 있으면 저장
  if [ "$GITHUB_AUTH_OK" = false ] && [ -n "${GITHUB_TOKEN:-}" ]; then
    git config --global credential.helper store
    printf 'https://oauth2:%s@github.com\n' "$GITHUB_TOKEN" > "$CRED_FILE"
    chmod 600 "$CRED_FILE"
    echo "[+] GITHUB_TOKEN으로 HTTPS 인증 정보 저장 완료"
    GITHUB_AUTH_OK=true
  fi

  # 4. git remote가 git@github.com:... 여도 HTTPS로 자동 변환되게 설정
  git config --global --unset-all url."https://github.com/".insteadOf 2>/dev/null || true
  git config --global url."https://github.com/".insteadOf "git@github.com:"
  git config --global --add url."https://github.com/".insteadOf "ssh://git@github.com/"

  echo ""
  echo "======= GitHub 인증 확인 (K8s) ======="
  echo ""

  if [ "$GITHUB_AUTH_OK" = true ]; then
    set +e
    git ls-remote https://github.com/github/gitignore.git HEAD >/dev/null 2>&1
    verify_result=$?
    set -e

    if [ $verify_result -eq 0 ]; then
      echo "[+] GitHub HTTPS 인증 확인 완료"
    else
      echo "[-] GitHub HTTPS 인증 실패 (토큰 권한/유효기간 또는 credential 확인 필요)"
      FAILURES+=("GitHub HTTPS 인증")
    fi
  else
    echo "[-] GitHub 토큰이 없어 HTTPS 인증 설정을 건너뜀"
    GIT_IDENTITY_SETUP_ENABLED=false
  fi

else
  echo "======= SSH 키 생성 및 설정 ======="
  echo ""

  SSH_DIR="$HOME/.ssh"
  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR"

  # SSH 키 생성 (없을 때만)
  if [ ! -f "$SSH_DIR/id_ed25519" ]; then
    ssh-keygen -t ed25519 -N "" -f "$SSH_DIR/id_ed25519" -C "$HOSTNAME-$(date +%F)"
    echo "[+] SSH 키 생성: $SSH_DIR/id_ed25519"
  else
    echo "[=] SSH 키 재사용: $SSH_DIR/id_ed25519"
  fi

  # .ssh/config 설정 (기존 설정에 추가)
  touch "$SSH_DIR/config"
  chmod 600 "$SSH_DIR/config"

  # GitHub 설정이 없으면 추가
  if ! grep -q "^Host github.com" "$SSH_DIR/config" 2>/dev/null; then
    cat >> "$SSH_DIR/config" <<EOF

Host github.com
  HostName github.com
  User git
  IdentityFile ${SSH_DIR}/id_ed25519
  IdentitiesOnly yes
EOF
    echo "[+] .ssh/config에 GitHub 설정 추가"
  else
    echo "[=] .ssh/config에 이미 GitHub 설정 존재"
  fi

  # known_hosts 설정
  touch "$SSH_DIR/known_hosts"
  if command -v ssh-keyscan >/dev/null 2>&1; then
    if ! ssh-keygen -F github.com >/dev/null 2>&1; then
      ssh-keyscan github.com >> "$SSH_DIR/known_hosts" 2>/dev/null || true
    fi
  fi
  chmod 600 "$SSH_DIR/known_hosts" || true

  echo ""
  echo "======= GitHub SSH 키 등록 확인 ======="
  echo ""

  set +e
  out="$(ssh -o BatchMode=yes -o IdentitiesOnly=yes -i "$SSH_DIR/id_ed25519" -T git@github.com 2>&1)"
  set -e

  if echo "$out" | grep -qi "you've successfully authenticated"; then
    echo "[+] GitHub SSH 인증 완료"
  else
    echo "GitHub SSH 인증 필요"
    echo ""
    echo "아래 공개키를 GitHub에 등록하세요:"
    echo "----------------------------------------------------------------"
    cat "$SSH_DIR/id_ed25519.pub"
    echo "----------------------------------------------------------------"
    echo ""
    echo "등록 페이지: https://github.com/settings/keys"
    echo ""
    read -r -p "[?] 등록 완료 후 Enter를 누르세요 (건너뛰려면 skip): " ans
    if [ "${ans:-}" != "skip" ]; then
      set +e
      out="$(ssh -o BatchMode=yes -o IdentitiesOnly=yes -i "$SSH_DIR/id_ed25519" -T git@github.com 2>&1)"
      set -e
      if echo "$out" | grep -qi "you've successfully authenticated"; then
        echo "✅ GitHub SSH 인증 확인 완료"
      else
        echo "❌ 인증되지 않음 - 나중에 다시 확인하세요"
      fi
    fi
  fi
fi


# ============================================================
# 3. 개발 도구 설치
# ============================================================
echo ""
echo "======= 개발 도구 설치 ======="
echo ""

# conda 사용 가능한지 확인 (이미 위에서 활성화했으므로)
if ! command -v conda >/dev/null 2>&1; then
  FAILURES+=("Conda 미설치로 개발 도구 설치 건너뜀")
else
  # conda Terms of Service 자동 수락 (기본 채널 사용 시 필요)
  if ! conda tos status 2>/dev/null | grep -q "accepted"; then
    conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main 2>/dev/null || true
    conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r 2>/dev/null || true
  fi

# 필요한 패키지 설치 (conda-forge 채널 사용)
install_tool() {
  local cmd="$1"
  local pkg="${2:-$1}"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "  - $pkg 설치 중..."
    if ! conda install -y -c conda-forge "$pkg" 2>/dev/null; then
      FAILURES+=("$pkg 설치")
    fi
  fi
}

install_tool curl
install_tool wget
install_tool git
install_tool git-lfs
install_tool tree
install_tool htop
install_tool tmux "tmux=3.5a"  # 3.6 버전 오류 회피 위해 3.5a로 고정

  # git-lfs 초기화
  if command -v git-lfs >/dev/null 2>&1; then
    if ! git lfs install 2>/dev/null; then
      FAILURES+=("git-lfs 초기화")
    fi
  fi
fi

# ============================================================
# 4. Git 기본 설정
# ============================================================
echo ""
echo "======= Git 기본 설정 ======="
echo ""

if command -v git >/dev/null 2>&1; then
  if [ "$GIT_IDENTITY_SETUP_ENABLED" = true ]; then
    current_name="$(git config --global user.name || true)"
    current_email="$(git config --global user.email || true)"

    if [ -n "$current_name" ]; then
      echo "[=] 기존 Git user.name 재사용: $current_name"
    else
      read -r -p "Git user.name 입력 (예: Your Name): " git_name
      if [ -n "${git_name:-}" ]; then
        git config --global user.name "$git_name"
        echo "[+] Git user.name 설정 완료"
      else
        echo "[!] Git user.name 입력을 건너뜀"
        FAILURES+=("Git user.name 미설정")
      fi
    fi

    if [ -n "$current_email" ]; then
      echo "[=] 기존 Git user.email 재사용: $current_email"
    else
      read -r -p "Git user.email 입력 (GitHub 연동 원하면 GitHub 계정 이메일): " git_email
      if [ -n "${git_email:-}" ]; then
        git config --global user.email "$git_email"
        echo "[+] Git user.email 설정 완료"
      else
        echo "[!] Git user.email 입력을 건너뜀"
        FAILURES+=("Git user.email 미설정")
      fi
    fi

    git config --global init.defaultBranch main
    git config --global pull.ff only
  else
    echo "[=] GitHub 토큰이 없어 Git 기본 설정을 건너뜀"
  fi
else
  echo "[-] git 명령을 찾을 수 없어 Git 기본 설정을 건너뜀"
  FAILURES+=("Git 기본 설정")
fi

# ============================================================
# 5. 설정 파일 복사
# ============================================================
echo ""
echo "======= 설정 파일 복사 ======="
echo ""

# .gitignore_global 복사 및 Git에 global gitignore 설정
cp -f "$SCRIPT_DIR/config/.gitignore_global" "$HOME/.gitignore_global"
chmod 600 "$HOME/.gitignore_global"

git config --global core.excludesfile "$HOME/.gitignore_global"
echo "[+] .gitignore_global 복사 및 설정 완료"

# .tmux.conf 복사
cp -f "$SCRIPT_DIR/config/.tmux.conf" "$HOME/.tmux.conf"
chmod 600 "$HOME/.tmux.conf"
echo "[+] .tmux.conf 복사 완료"

# .bashrc 설정을 ~/.bashrc에 추가 (idempotent)
BASHRC="$HOME/.bashrc"
touch "$BASHRC"

# 마커 확인
if grep -q "# >>> bootstrap settings >>>" "$BASHRC" 2>/dev/null; then
  # 기존 설정 제거 (마커 사이의 내용)
  sed '/# >>> bootstrap settings >>>/,/# <<< bootstrap settings <<</d' "$BASHRC" > "$BASHRC.tmp"
  mv "$BASHRC.tmp" "$BASHRC"
fi

# 새로운 설정 추가
{
  echo "# >>> bootstrap settings >>>"
  cat "$SCRIPT_DIR/config/.bashrc"
  echo "# <<< bootstrap settings <<<"
} >> "$BASHRC"
source "$HOME/.bashrc"

echo "[+] .bashrc 설정 추가 완료"

# ============================================================
# 6. 완료
# ============================================================
echo ""
if [ ${#FAILURES[@]} -eq 0 ]; then
  echo "✅ SETUP 완료!"
else
  echo "⚠️  SETUP 완료 (일부 실패)"
  echo ""
  echo "실패한 항목:"
  for failure in "${FAILURES[@]}"; do
    echo "  ❌ $failure"
  done
fi
echo ""

# exec bash
