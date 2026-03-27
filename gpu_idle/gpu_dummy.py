#!/usr/bin/env python3
"""
GPU 더미 자동 실행기
- 기본: 모든 GPU에서 100% 더미 부하 자동 실행
- 자동 감지: Dummy가 아닌 프로세스 감지 시 즉시 감지 모드로 전환
- 자동 복귀: 5분 동안 프로세스 없으면 자동으로 더미 모드 복귀
- 수동 제어: stop 명령으로 특정 GPU를 감지 모드로 전환 가능
"""

import subprocess, time, os, sys, signal
from typing import Dict, List, Tuple, Optional
import datetime as dt

POLL_INTERVAL_SEC = 1
IDLE_THRESHOLD_SEC = 5 * 60  # 5분
NVIDIA_SMI = "nvidia-smi"
DASHBOARD_INTERVAL = 2  # 대시보드 업데이트 주기
DUMMY_MATMUL_SIZE = 4096
DUMMY_GRAPH_REPEATS = 8

_prev_lines = 0

def _render_dashboard(lines: List[str]) -> None:
    """터미널에 lines를 같은 위치에 덮어쓰기"""
    global _prev_lines
    if sys.stdout.isatty() and _prev_lines > 0:
        for _ in range(_prev_lines):
            sys.stdout.write("\x1b[1A\x1b[2K")
    sys.stdout.write("\n".join(lines) + "\n")
    sys.stdout.flush()
    _prev_lines = len(lines)

def now() -> str:
    return dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

def fmt_time(seconds: int) -> str:
    if seconds <= 0:
        return "0s"
    m, s = divmod(seconds, 60)
    h, m = divmod(m, 60)
    if h > 0:
        return f"{h}h{m}m"
    elif m > 0:
        return f"{m}m{s}s"
    return f"{s}s"

def read_gpu_utils() -> List[Tuple[int, int]]:
    """각 GPU index, utilization.gpu% 반환"""
    cmd = [NVIDIA_SMI, "--query-gpu=index,utilization.gpu", "--format=csv,noheader,nounits"]
    res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if res.returncode != 0:
        return []
    out = []
    for line in res.stdout.strip().split('\n'):
        if not line.strip():
            continue
        parts = [p.strip() for p in line.split(",")]
        if len(parts) == 2:
            try:
                out.append((int(parts[0]), int(parts[1])))
            except ValueError:
                pass
    return out

def read_gpu_processes() -> Dict[int, List[Tuple[int, str]]]:
    """각 GPU에서 실행 중인 프로세스 (pid, 이름) 목록 반환"""
    cmd = [NVIDIA_SMI, "--query-compute-apps=gpu_uuid,pid,process_name", "--format=csv,noheader"]
    res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if res.returncode != 0:
        return {}
    
    # GPU UUID to index 매핑
    uuid_cmd = [NVIDIA_SMI, "--query-gpu=index,gpu_uuid", "--format=csv,noheader"]
    uuid_res = subprocess.run(uuid_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    uuid_to_idx = {}
    if uuid_res.returncode == 0:
        for line in uuid_res.stdout.strip().split('\n'):
            if not line.strip():
                continue
            parts = [p.strip() for p in line.split(",")]
            if len(parts) == 2:
                try:
                    uuid_to_idx[parts[1]] = int(parts[0])
                except ValueError:
                    pass
    
    # GPU별 프로세스 이름 수집
    gpu_procs: Dict[int, List[Tuple[int, str]]] = {}
    for line in res.stdout.strip().split('\n'):
        if not line.strip():
            continue
        parts = [p.strip() for p in line.split(",", 2)]
        if len(parts) == 3:
            gpu_uuid, pid_str, proc_name = parts[0], parts[1], parts[2]
            if gpu_uuid in uuid_to_idx:
                try:
                    pid = int(pid_str)
                except ValueError:
                    continue
                gpu_id = uuid_to_idx[gpu_uuid]
                if gpu_id not in gpu_procs:
                    gpu_procs[gpu_id] = []
                # 프로세스 이름에서 경로 제거 (basename만)
                proc_basename = os.path.basename(proc_name)
                gpu_procs[gpu_id].append((pid, proc_basename))
    
    return gpu_procs

def _read_pid_cmdline(pid: int) -> str:
    """PID의 cmdline 조회 (실패 시 빈 문자열)"""
    try:
        with open(f"/proc/{pid}/cmdline", "rb") as f:
            raw = f.read()
        if not raw:
            return ""
        return raw.replace(b"\x00", b" ").decode("utf-8", errors="ignore").strip()
    except Exception:
        return ""

def is_dummy_process(pid: int, proc_name: str) -> bool:
    """해당 PID가 이 스크립트의 더미 워커인지 판별"""
    if proc_name.startswith("GPU"):
        return True
    cmdline = _read_pid_cmdline(pid)
    if not cmdline:
        return False
    script_name = os.path.basename(__file__)
    return (
        f"{script_name} --worker" in cmdline
        or "run_dummy_worker" in cmdline
    )

def run_dummy_worker(gpu_id: int) -> None:
    """별도 프로세스에서 지정 GPU에 더미 부하 실행"""
    # 프로세스 이름 변경
    try:
        import setproctitle
        setproctitle.setproctitle(f"GPU{gpu_id}")
    except ImportError:
        # setproctitle 없으면 prctl 시도
        try:
            import ctypes
            libc = ctypes.CDLL("libc.so.6")
            PR_SET_NAME = 15
            name = f"GPU{gpu_id}"[:15].encode('utf-8')
            libc.prctl(PR_SET_NAME, ctypes.c_char_p(name), 0, 0, 0)
        except Exception:
            pass
    
    try:
        import torch
    except Exception:
        sys.exit(1)

    if not torch.cuda.is_available() or gpu_id >= torch.cuda.device_count():
        sys.exit(1)

    device = torch.device(f"cuda:{gpu_id}")
    torch.cuda.set_device(gpu_id)

    torch.backends.cuda.matmul.allow_tf32 = True
    torch.backends.cudnn.allow_tf32 = True

    dtype = torch.float16
    a = torch.randn(DUMMY_MATMUL_SIZE, DUMMY_MATMUL_SIZE, device=device, dtype=dtype)
    b = torch.randn(DUMMY_MATMUL_SIZE, DUMMY_MATMUL_SIZE, device=device, dtype=dtype)
    c = torch.empty_like(a)

    warmup_stream = torch.cuda.Stream(device=device)
    with torch.cuda.stream(warmup_stream):
        for _ in range(DUMMY_GRAPH_REPEATS):
            torch.matmul(a, b, out=c)
    torch.cuda.current_stream(device).wait_stream(warmup_stream)
    torch.cuda.synchronize(device)

    # CUDA graph 재사용으로 Python/launch 오버헤드를 줄여 CPU 영향을 낮춘다.
    graph = torch.cuda.CUDAGraph()
    with torch.cuda.graph(graph):
        for _ in range(DUMMY_GRAPH_REPEATS):
            torch.matmul(a, b, out=c)

    # SIGTERM 핸들러
    def handler(signum, frame):
        sys.exit(0)
    signal.signal(signal.SIGTERM, handler)

    try:
        while True:
            graph.replay()
    except KeyboardInterrupt:
        pass
    finally:
        try:
            torch.cuda.synchronize()
            torch.cuda.empty_cache()
        except Exception:
            pass

class GPUManager:
    def __init__(self):
        self.gpu_count = 0
        self.modes: Dict[int, str] = {}  # 'dummy' or 'watch'
        self.processes: Dict[int, Optional[subprocess.Popen]] = {}
        self.idle_start: Dict[int, float] = {}
        
    def init_gpus(self):
        """GPU 초기화 및 더미 모드로 시작"""
        utils = read_gpu_utils()
        if not utils:
            print("GPU를 찾을 수 없습니다.")
            return False
        
        for gpu_id, _ in utils:
            self.gpu_count = max(self.gpu_count, gpu_id + 1)
            self.modes[gpu_id] = 'dummy'
            self.idle_start[gpu_id] = 0
            self.processes[gpu_id] = None
            self.start_dummy(gpu_id)
        
        print(f"[{now()}] {self.gpu_count}개 GPU 감지, 모두 더미 모드로 시작")
        return True
    
    def start_dummy(self, gpu_id: int):
        """더미 모드 시작 (별도 프로세스)"""
        self.stop_dummy(gpu_id)
        
        # 별도 프로세스로 워커 실행
        cmd = [sys.executable, os.path.abspath(__file__), "--worker", str(gpu_id)]
        
        try:
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL
            )
            self.processes[gpu_id] = proc
            self.modes[gpu_id] = 'dummy'
            self.idle_start[gpu_id] = 0
        except Exception:
            self.processes[gpu_id] = None
    
    def stop_dummy(self, gpu_id: int):
        """더미 모드 중지 (프로세스 종료)"""
        if gpu_id in self.processes and self.processes[gpu_id] is not None:
            proc = self.processes[gpu_id]
            try:
                proc.terminate()
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
            except Exception:
                pass
            self.processes[gpu_id] = None
    

    
    def update(self):
        """상태 업데이트 (프로세스 기반 자동 감지 및 복귀)"""
        # GPU 프로세스 체크
        gpu_procs = read_gpu_processes()
        
        t = time.time()
        
        for gpu_id in range(self.gpu_count):
            proc = self.processes.get(gpu_id)
            if proc is not None and proc.poll() is not None:
                self.processes[gpu_id] = None
                proc = None

            # 더미 모드인데 프로세스가 죽었으면 즉시 재시작
            if self.modes.get(gpu_id) == 'dummy' and proc is None:
                self.start_dummy(gpu_id)
                continue

            procs = gpu_procs.get(gpu_id, [])
            dummy_pid = proc.pid if proc is not None else None
            
            # Dummy 프로세스 제외한 실제 프로세스 확인
            non_dummy_procs = [
                name for pid, name in procs
                if pid != dummy_pid and not is_dummy_process(pid, name)
            ]
            has_process = len(non_dummy_procs) > 0
            
            # [자동 감지] Dummy가 아닌 프로세스 감지 시 즉시 감지 모드로 전환
            if self.modes.get(gpu_id) == 'dummy':
                if has_process:
                    self.stop_dummy(gpu_id)
                    self.modes[gpu_id] = 'watch'
                    self.idle_start[gpu_id] = 0
                    continue
            
            # [감지 모드] 프로세스 없으면 5분 대기 후 더미 복귀
            if self.modes.get(gpu_id) == 'watch':
                if not has_process:
                    # 프로세스가 없으면 idle 카운트 시작
                    if self.idle_start[gpu_id] == 0:
                        self.idle_start[gpu_id] = t
                    
                    idle_duration = t - self.idle_start[gpu_id]
                    if idle_duration >= IDLE_THRESHOLD_SEC:
                        # [자동 복귀] 5분 동안 프로세스 없음 -> 더미 모드로 복귀
                        print(f"\n[{now()}] [GPU{gpu_id}] 5분 동안 프로세스 없음, 더미 모드로 복귀")
                        self.start_dummy(gpu_id)
                else:
                    # 프로세스 있으면 idle 카운터 초기화
                    self.idle_start[gpu_id] = 0
    
    def get_status_lines(self) -> List[str]:
        """대시보드 출력용 상태 라인"""
        lines = [f"[{now()}] GPU 더미 자동 실행기 (프로세스 기반 감지)"]
        
        # 현재 프로세스 상태 조회
        gpu_procs = read_gpu_processes()
        
        t = time.time()
        for gpu_id in range(self.gpu_count):
            mode = self.modes.get(gpu_id, 'unknown')
            procs = gpu_procs.get(gpu_id, [])
            proc = self.processes.get(gpu_id)
            if proc is not None and proc.poll() is not None:
                proc = None
            dummy_pid = proc.pid if proc is not None else None
            non_dummy_procs = [
                name for pid, name in procs
                if pid != dummy_pid and not is_dummy_process(pid, name)
            ]
            
            if mode == 'dummy':
                if proc is None:
                    lines.append(f"  [GPU{gpu_id}] 더미 모드 - 워커 재시작 중")
                else:
                    lines.append(f"  [GPU{gpu_id}] 더미 모드 실행중 (pid={proc.pid})")
            elif mode == 'watch':
                if len(non_dummy_procs) > 0:
                    proc_names = ", ".join(non_dummy_procs[:2])  # 최대 2개만 표시
                    if len(non_dummy_procs) > 2:
                        proc_names += f" +{len(non_dummy_procs)-2}"
                    lines.append(f"  [GPU{gpu_id}] 감지 모드 - 사용중 ({proc_names})")
                elif self.idle_start[gpu_id] > 0:
                    idle_dur = int(t - self.idle_start[gpu_id])
                    remain = max(0, IDLE_THRESHOLD_SEC - idle_dur)
                    lines.append(f"  [GPU{gpu_id}] 감지 모드 - 대기 {fmt_time(idle_dur)} / {fmt_time(IDLE_THRESHOLD_SEC)} (남은 {fmt_time(remain)})")
                else:
                    lines.append(f"  [GPU{gpu_id}] 감지 모드 - 대기 중")
        
        return lines

def main():
    # 워커 모드 체크 (내부 호출용)
    if len(sys.argv) > 1 and sys.argv[1] == '--worker':
        gpu_id = int(sys.argv[2])
        run_dummy_worker(gpu_id)
        return 0
    
    manager = GPUManager()
    
    if not manager.init_gpus():
        return 1
    
    last_dashboard = 0
    
    try:
        while True:
            manager.update()
            
            # 대시보드 업데이트
            if time.time() - last_dashboard >= DASHBOARD_INTERVAL:
                _render_dashboard(manager.get_status_lines())
                last_dashboard = time.time()
            
            time.sleep(POLL_INTERVAL_SEC)
    except KeyboardInterrupt:
        print(f"\n[{now()}] 종료 중...")
        for gpu_id in range(manager.gpu_count):
            manager.stop_dummy(gpu_id)
        print("종료됨")
    
    return 0

if __name__ == "__main__":
    sys.exit(main())
