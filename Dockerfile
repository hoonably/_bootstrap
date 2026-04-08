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
    PATH=/opt/conda/bin:$PATH

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

RUN python -m pip install --upgrade pip && \
    pip install --no-cache-dir jupyterlab notebook ipykernel

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

CMD ["sh", "-c", "jupyter lab --notebook-dir=${HOME} --ip=0.0.0.0 --no-browser --allow-root --port=8888 --ServerApp.token='' --ServerApp.password='' --ServerApp.allow_origin='*' --ServerApp.allow_remote_access=True --ServerApp.base_url=${NB_PREFIX}"]