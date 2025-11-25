


# GPU Dummy Auto Runner

GPU 유휴 시간을 최소화하기 위한 자동 더미 부하 실행기

## 개요

- **기본 동작**: 모든 GPU에서 100% 더미 부하 자동 실행
- **감지 모드**: 외부 명령으로 특정 GPU를 감지 모드로 전환
- **자동 복귀**: 30분 연속 0% 사용량 감지 시 자동으로 더미 모드 복귀
- **메모리 관리**: 감지 모드에서는 프로세스 완전 종료로 GPU 메모리 0MB 유지

## 설치 및 설정

### 1. 환경 변수 설정
```bash
source /home/ubuntu/hoon/_bootstrap/env.sh
```

`env.sh`에 다음 alias 추가됨:
```bash
alias stop='bash /home/ubuntu/hoon/_bootstrap/gpu_idle/stop'
```

### 2. 의존성
- Python 3.x
- PyTorch (CUDA 지원)
- nvidia-smi
- setproctitle (선택사항, 프로세스 이름 표시용)

## 사용법

### tmux 세션에서 실행
```bash
tmux new -s gpu_dummy "python gpu_dummy_auto.py"
```

### GPU 감지 모드 전환
```bash
# 모든 GPU를 감지 모드로 전환
stop

# 특정 GPU만 감지 모드로 전환
stop 0
stop 1
```

### tmux 세션 관리
```bash
# 세션 확인
tmux ls

# 세션 재접속
tmux attach -t gpu_dummy

# 세션 종료
tmux kill-session -t gpu_dummy
```

## 동작 흐름

1. **더미 모드** (기본)
   - 각 GPU에서 별도 프로세스로 100% 부하 실행
   - 프로세스 이름: `Dummy-GPU0`, `Dummy-GPU1`, ...
   - GPU 메모리: ~780MB 사용

2. **감지 모드** (`stop` 명령 후)
   - 더미 프로세스 완전 종료
   - GPU 메모리: 0MB
   - 30분 동안 사용량 모니터링

3. **자동 복귀**
   - 30분 연속 0% 사용량 → 자동으로 더미 모드 복귀
   - 중간에 사용하면 타이머 리셋

## 예시 시나리오

```
초기 상태: 모든 GPU 더미 모드 (100%)
  ↓
사용자: stop 1
  ↓
GPU 1: 감지 모드 진입 (0%), GPU 0: 더미 모드 유지
  ↓
5분 후: 사용자가 GPU 1에서 추론 시작 (80%)
  ↓
추론 종료: GPU 1 다시 0%, 타이머 리셋
  ↓
30분 대기...
  ↓
30분 연속 0%: GPU 1 자동으로 더미 모드 복귀
```

## 대시보드 출력

```
[2025-11-25 10:30:00] GPU 더미 자동 실행기
  [GPU0] 더미 모드 실행중 (util=98%)
  [GPU1] 감지 모드 - 사용중 (util=75%)
  [GPU2] 감지 모드 - 유휴 5m30s / 30m0s (남은시간 24m30s)
```

## 설정 변경

`gpu_dummy_auto.py` 상단 설정:
```python
POLL_INTERVAL_SEC = 1          # nvidia-smi 폴링 주기 (초)
IDLE_THRESHOLD_SEC = 30 * 60   # 유휴 임계값 (30분)
DASHBOARD_INTERVAL = 2         # 대시보드 업데이트 주기 (초)
```

## 트러블슈팅

### 프로세스 이름이 표시되지 않는 경우
```bash
pip install setproctitle
```

### GPU 메모리가 해제되지 않는 경우
- 감지 모드로 전환했는지 확인
- 프로세스가 정상 종료되었는지 확인: `nvidia-smi`

### tmux 세션이 응답하지 않는 경우
```bash
tmux kill-session -t gpu_dummy
python gpu_dummy_auto.py  # 직접 실행하여 에러 확인
```