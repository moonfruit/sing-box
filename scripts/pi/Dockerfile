ARG GO_VERSION=1.26
FROM golang:${GO_VERSION}-bookworm AS go
FROM node:24-bookworm
COPY --from=go /usr/local/go /usr/local/go
ENV PATH="/usr/local/go/bin:${PATH}" HOME=/tmp PI_CODING_AGENT_DIR=/var/tmp/pi-agent
RUN npm install --global --ignore-scripts @earendil-works/pi-coding-agent@1.5.2 \
    && install -d -m 1777 /var/tmp/pi-agent
COPY models.json /var/tmp/pi-agent/models.json
