FROM nvcr.io/nvidia/pytorch:24.05-py3
# 서버마다 CUDA/driver 호환성 안 맞으면 이 줄만 바꾸기

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Seoul \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    NB_USER=hoon \
    NB_UID=500 \
    NB_GID=500 \
    HOME=/home/hoon \
    SHELL=/bin/bash \
    NB_PREFIX=/ \
    CONDA_DIR=/opt/conda \
    PATH=$PATH:/opt/conda/bin

RUN apt-get update && apt-get install -y --no-install-recommends \
    sudo git git-lfs curl wget vim tree tmux htop \
    ca-certificates openssh-server \
    && rm -rf /var/lib/apt/lists/*

RUN git lfs install --system

RUN wget -qO /tmp/miniforge.sh \
    https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh && \
    bash /tmp/miniforge.sh -b -p ${CONDA_DIR} && \
    rm -f /tmp/miniforge.sh && \
    conda config --system --set auto_activate_base false && \
    conda clean -afy

# NVIDIA 이미지의 기본 Python/PyTorch CUDA 스택을 유지한다.
# Miniforge는 사용자 conda 환경 생성용으로만 PATH 뒤에 둔다.
RUN /usr/local/bin/python -m pip install --upgrade pip && \
    /usr/local/bin/python -m pip install --no-cache-dir jupyterlab notebook ipykernel && \
    /usr/local/bin/python -c "import torch; print('torch', torch.__version__)"

RUN groupadd -g ${NB_GID} ${NB_USER} && \
    useradd -m -s /bin/bash -u ${NB_UID} -g ${NB_GID} ${NB_USER} && \
    echo "${NB_USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${NB_USER} && \
    chmod 0440 /etc/sudoers.d/${NB_USER} && \
    mkdir -p /home/${NB_USER} && \
    chown -R ${NB_USER}:${NB_USER} /home/${NB_USER}

RUN mkdir -p /home/${NB_USER}/.conda/envs /home/${NB_USER}/.conda/pkgs && \
    chown -R ${NB_USER}:${NB_USER} /home/${NB_USER}/.conda && \
    printf "envs_dirs:\n  - /home/%s/.conda/envs\npkgs_dirs:\n  - /home/%s/.conda/pkgs\n" "${NB_USER}" "${NB_USER}" > /home/${NB_USER}/.condarc && \
    chown ${NB_USER}:${NB_USER} /home/${NB_USER}/.condarc

USER ${NB_USER}
WORKDIR /home/${NB_USER}

EXPOSE 8888

# 이 이미지는 인증된 Kubernetes ingress/proxy 뒤에서만 사용한다.
# Jupyter 자체 인증을 끄므로 8888 포트를 외부에 직접 publish하지 않는다.
CMD ["sh", "-c", "exec /usr/local/bin/python -m jupyter lab --notebook-dir=${HOME} --ip=0.0.0.0 --no-browser --allow-root --port=8888 --ServerApp.token='' --ServerApp.password='' --ServerApp.allow_origin='*' --ServerApp.allow_remote_access=True --ServerApp.base_url=${NB_PREFIX}"]
