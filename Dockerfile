# Multicam Studio as a network service: the web interface is served on port 8765
# and renders run inside the container. Mount your recordings and export folders.
FROM python:3.12-slim

# Debian's FFmpeg includes libx264, which the editor uses for H.264 output.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY server.py multicam_edit.py effects.py ./
COPY web ./web

# /state holds preferences, job history, uploads and previews. It is world-writable
# so the container can run as any user (see PUID/PGID in docker-compose.yml).
RUN mkdir -p /state /media/recordings /media/exports && chmod 1777 /state

ENV PYTHONUNBUFFERED=1 \
    HOME=/tmp \
    MULTICAM_HOST=0.0.0.0 \
    MULTICAM_PORT=8765 \
    MULTICAM_STATE_DIR=/state \
    MULTICAM_DEFAULT_FOLDER=/media/recordings \
    MULTICAM_DEFAULT_OUTPUT=/media/exports \
    MULTICAM_ROOTS=/media

EXPOSE 8765
VOLUME ["/state"]
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
    CMD ["python", "-c", "import os, urllib.request; urllib.request.urlopen('http://127.0.0.1:%s/api/health' % os.environ.get('MULTICAM_PORT', '8765'), timeout=4)"]
CMD ["python", "server.py"]
