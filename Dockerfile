FROM nvidia/cuda:12.8.1-runtime-ubuntu22.04

# Set timezone and configure non-interactive installation
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# Install Python 3.12 from deadsnakes PPA and build tools
RUN apt-get update \
    && apt-get install -y software-properties-common \
    && add-apt-repository ppa:deadsnakes/ppa -y \
    && apt-get update \
    && apt-get install -y git python3.12 python3.12-venv python3.12-dev ffmpeg curl tzdata \
       build-essential gcc g++ make \
    && apt-get clean  \
    && rm -rf /var/lib/apt/lists/*

# Install uv
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:$PATH"
ENV UV_LINK_MODE=copy

# copy pyproject.toml and uv.lock first to leverage container image build cache
COPY ./pyproject.toml ./uv.lock /app/UltraSinger/
# Need to copy some minimal source structure for editable install
RUN mkdir -p /app/UltraSinger/src
WORKDIR /app/UltraSinger

# Install the exact versions pinned in uv.lock (unpinned deps like swift-f0 have had breaking API changes),
# directly without venv (container is already isolated)
RUN uv export --frozen --no-dev --no-hashes --no-emit-project -o /tmp/requirements.txt \
    && uv pip install --system --python 3.12 -r /tmp/requirements.txt \
    && uv pip install --system --python 3.12 --no-deps -e . \
    && rm /tmp/requirements.txt

# Install PyTorch with CUDA support (override the CPU version from pyproject.toml)
# Only reinstall the torch packages: a blanket --reinstall also pulls newer deps (e.g. numpy) from the PyTorch index,
# overriding the uv.lock versions.
RUN uv pip install --system --python 3.12 torch==2.8.0 torchvision==0.23.0 torchaudio==2.8.0 --index-url https://download.pytorch.org/whl/cu128 \
    --reinstall-package torch --reinstall-package torchvision --reinstall-package torchaudio

# YouTube changes constantly, so always take the latest yt-dlp (+ yt-dlp-ejs challenge solver) and deno rather than the locked versions.
# Kept as its own late layer; bump YTDLP_REFRESH (e.g. --build-arg YTDLP_REFRESH=$(date +%s)) to re-pull it cheaply.
ARG YTDLP_REFRESH=0
RUN echo "yt-dlp refresh: $YTDLP_REFRESH" && uv pip install --system --python 3.12 --upgrade "yt-dlp[default]" deno

# Ubuntu 22.04's python3 is 3.10, but dependencies are installed for 3.12.
# Point python/python3 at 3.12 via /usr/local/bin (ahead of /usr/bin on PATH) so apt's own /usr/bin/python3 is untouched.
RUN ln -sf /usr/bin/python3.12 /usr/local/bin/python3 \
    && ln -sf /usr/bin/python3.12 /usr/local/bin/python

# copy sources late to allow for caching of layers which contain all the dependencies
COPY . /app/UltraSinger


# no need to run as root
# Create a real user with a home dir so numba/matplotlib/model caches (~/.cache, ~/.config) are writable
RUN groupadd -g 1000 ultrasinger \
    && useradd -m -u 1000 -g 1000 -s /bin/bash ultrasinger \
    && chown -R 1000:1000 /app/UltraSinger
USER 1000:1000
ENV HOME=/home/ultrasinger

WORKDIR /app/UltraSinger/src
CMD ["bash"]
