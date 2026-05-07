# Multi-stage Dockerfile for dvai-bridge rendezvous server.
# Final image is ~120 MB (Alpine + Node 22 LTS + the compiled JS).

FROM node:22-alpine AS builder
WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm install --include=dev
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

FROM node:22-alpine AS runtime
WORKDIR /app
ENV NODE_ENV=production
COPY package.json package-lock.json* ./
RUN npm install --omit=dev && npm cache clean --force
COPY --from=builder /app/dist ./dist

# Healthcheck so orchestrators (Kubernetes, ECS, etc.) can see liveness.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -qO- http://127.0.0.1:${PORT:-8080}/health || exit 1

EXPOSE 8080
USER node
CMD ["node", "dist/server.js"]
