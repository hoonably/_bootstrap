#!/usr/bin/env bash
set -euo pipefail

echo "=== [SETUP_OS] Start ==="

# sudo 유무에 따른 APT 래퍼
need_sudo=false
if command -v sudo >/dev/null 2>&1; then
  need_sudo=true
fi
APT() {
  if $need_sudo; then sudo apt-get "$@"; else apt-get "$@"; fi
}

# apt 캐시 업데이트는 최대 1회만
if [ ! -f /var/lib/apt/periodic/update-success-stamp ] || [ $(( $(date +%s) - $(date -r /var/lib/apt/periodic/update-success-stamp +%s) )) -gt 1800 ]; then
  export DEBIAN_FRONTEND=noninteractive
  APT update -y || true
fi

# 필요한 패키지 설치
install_pkg_if_missing () {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "[*] Installing $1..."
    export DEBIAN_FRONTEND=noninteractive
    case "$1" in
      tmux) APT install -y tmux ;;
      tree) APT install -y tree ;;
      wget) APT install -y wget ;;
      curl) APT install -y curl ;;
      git)  APT install -y git ;;
      git-lfs) APT install -y git-lfs ;;
      *) APT install -y "$1" ;;
    esac
  else
    echo "[=] $1 already present: $(command -v "$1")"
  fi
}

install_pkg_if_missing tmux
install_pkg_if_missing tree
install_pkg_if_missing wget
install_pkg_if_missing curl
install_pkg_if_missing git
install_pkg_if_missing git-lfs

# Miniconda 설치
if ! command -v conda >/dev/null 2>&1; then
  echo "[*] Installing Miniconda..."
  cd ~
  wget -q https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O miniconda.sh
  bash miniconda.sh -b -p "$HOME/miniconda3"
  rm -f miniconda.sh

  # conda init
  if ! grep -q 'conda initialize' ~/.bashrc 2>/dev/null; then
    "$HOME/miniconda3/bin/conda" init bash || true
  fi
  echo "[+] Miniconda installed"
else
  echo "[=] Conda already installed: $(command -v conda)"
fi

# 적용
# shellcheck disable=SC1090
source ~/.bashrc || true

echo "[OK] ✅ SETUP_OS finished"
