FROM nginx:1.27-alpine

# 不要ファイル削除
RUN rm -rf /usr/share/nginx/html/*

# Nginx設定コピー
COPY nginx/default.conf /etc/nginx/templates/default.conf.template

# 静的ファイルコピー
COPY public/ /usr/share/nginx/html/

# Cloud Run は PORT 環境変数でリッスンポートを指定する
ENV PORT=8080
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD wget -qO- http://localhost:${PORT}/healthz || exit 1

# nginx:alpine は /etc/nginx/templates/*.template を自動で envsubst 処理する
CMD ["nginx", "-g", "daemon off;"]
