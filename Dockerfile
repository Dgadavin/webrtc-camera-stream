FROM node:22-alpine

WORKDIR /app

COPY server.js ./
COPY public ./public
COPY cameras.json ./

ENV MEDIAMTX_API=10.8.0.1:9997
ENV MEDIAMTX_WHEP=10.8.0.1:8889
ENV CAMERAS_FILE=/app/cameras.json

ENV PORT=8080
EXPOSE 8080

CMD ["node", "server.js"]
