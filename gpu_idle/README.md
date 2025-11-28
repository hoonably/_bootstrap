# GPU Dummy Auto Runner

GPU 유휴 시간을 최소화하기 위한 자동 더미 부하 실행기

## 핵심 기능

- **자동 감지**: GPU에 프로세스 올라오면 즉시 더미 중지
- **자동 복귀**: 5분 동안 프로세스 없으면 더미 재시작

## 설치 및 실행

### 1. Conda 가상환경 생성 및 활성화

```bash
conda create -n gpu-dummy python=3.9 -y
conda activate gpu-dummy
```

### 2. 의존성 설치

```bash
# PyTorch (CUDA 12.1 기준, 버전에 맞게 변경)
conda install pytorch torchvision torchaudio pytorch-cuda=12.1 -c pytorch -c nvidia -y

# 프로세스 이름 표시용 (권장)
pip install setproctitle
```

### 3. 실행

- gpu_idle 경로로 이동
```bash
cd _bootstrap
cd gpu_idle
```

- tmux 실행
```bash
tmux new -s dummy "bash -i -c 'conda activate gpu-dummy && python gpu_dummy.py'"
```

## 진행상황 보기

```bash
tmux attach -t dummy
```

(빠져나오기: `Ctrl+b` 누른 후 `d`)

## tmux 세션 삭제

```bash
tmux kill-session -t dummy
```

### 동작 원리

```
더미 모드 (GPU 100% 유지)
  ↓
프로세스 감지 → 즉시 더미 중지
  ↓
작업 실행 중...
  ↓
작업 종료 → 5분 대기
  ↓
5분 동안 프로세스 없음 → 더미 재시작
```

## 설정 변경

`gpu_dummy.py` 파일 상단:
```python
IDLE_THRESHOLD_SEC = 5 * 60    # 5분 → 원하는 시간으로 변경
```