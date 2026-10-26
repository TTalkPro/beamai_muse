FROM node:22-bookworm-slim

RUN sed -i 's|http://deb.debian.org|http://mirrors.ustc.edu.cn|g' /etc/apt/sources.list.d/debian.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates chromium fonts-liberation fonts-noto-core fonts-noto-cjk \
       fonts-noto-color-emoji \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts
COPY src ./src
COPY vendor ./vendor
RUN mkdir /data && chown node:node /data

USER node
ENV NODE_ENV=production \
    WORKER_DATA_DIR=/data \
    WORKER_HOST=0.0.0.0 \
    CHROMIUM_PATH=/usr/bin/chromium
EXPOSE 8790
VOLUME /data
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD ["node", "-e", "fetch('http://127.0.0.1:8790/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]
CMD ["node", "--experimental-strip-types", "src/index.ts"]
