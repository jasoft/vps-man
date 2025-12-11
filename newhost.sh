#!/bin/bash
  set -euo pipefail

  DOMAIN="wp2.ursoftware.com"
  EMAIL="admin@${DOMAIN}"
  CERT_DIR="/etc/ssl/${DOMAIN}"
  SITE_DIR="/opt/wp2/html"
  CONF_DIR="/opt/wp2"
  HYST_PASS="${HYST_PASS:-$(openssl rand -hex 12)}"

  echo "[+] Installing Docker & deps"
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg lsb-release
  if ! command -v docker >/dev/null 2>&1; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/
  keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/
  keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/
  os-release && echo $VERSION_CODENAME) stable" > /etc/apt/sources.list.d/
  docker.list
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-
  plugin docker-compose-plugin
    systemctl enable --now docker
  fi

  echo "[+] Stop/disable host nginx if present to free 80/443"
  systemctl disable --now nginx 2>/dev/null || true

  echo "[+] Portainer"
  docker volume create portainer_data >/dev/null 2>&1 || true
  docker rm -f portainer >/dev/null 2>&1 || true
  docker run -d --name portainer --restart=always -p 8000:8000 -p 9000:9000
  -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data
  portainer/portainer-ce:latest >/dev/null

  echo "[+] Site files"
  mkdir -p "${SITE_DIR}"
  if [ ! -f "${SITE_DIR}/index.html" ]; then
  cat > "${SITE_DIR}/index.html" <<'EOF'
  <!DOCTYPE html><html><head><meta charset="utf-8"><meta
  name="viewport" content="width=device-width,initial-
  scale=1"><title>Setup OK</title></head><body style="display:flex;align-
  items:center;justify-content:center;height:100vh;font-
  family:Arial;background:#0f172a;color:#e2e8f0;"><div><h1>Success</
  h1><p>wp2.ursoftware.com is served by Dockerized Nginx.</p></div></
  body></html>
  EOF
  fi

  echo "[+] Nginx conf"
  mkdir -p "${CONF_DIR}"
  cat > "${CONF_DIR}/nginx.conf" <<EOF
  server {
      listen 80;
      listen 443 ssl http2;
      server_name ${DOMAIN};

      ssl_certificate /certs/fullchain.cer;
      ssl_certificate_key /certs/${DOMAIN}.key;
      ssl_session_cache shared:SSL:10m;
      ssl_session_timeout 10m;

      root /usr/share/nginx/html;
      index index.html;

      location / { try_files \$uri \$uri/ =404; }
      location /.well-known/acme-challenge/ { root /usr/share/nginx/html; }
  }
  EOF

  echo "[+] Hysteria2 config (password: ${HYST_PASS})"
  cat > "${CONF_DIR}/hysteria.yaml" <<EOF
  listen: :443
  tls:
    cert: /certs/fullchain.cer
    key: /certs/${DOMAIN}.key
  auth:
    type: password
    password: ${HYST_PASS}
  masquerade:
    type: proxy
    proxy:
      url: https://www.wikipedia.org
  EOF

  echo "[+] Docker Compose stack"
  cat > "${CONF_DIR}/docker-compose.yml" <<EOF
  services:
    nginx:
      image: nginx:1.25
      container_name: wp2-nginx
      restart: always
      ports:
        - "80:80/tcp"
        - "443:443/tcp"
      volumes:
        - ${CONF_DIR}/nginx.conf:/etc/nginx/conf.d/default.conf:ro
        - ${SITE_DIR}:/usr/share/nginx/html:ro
        - ${CERT_DIR}:/certs:ro

    hysteria2:
      image: teddysun/hysteria
      container_name: hysteria2
      restart: always
      ports:
        - "443:443/udp"
      volumes:
        - ${CONF_DIR}/hysteria.yaml:/etc/hysteria/server.yaml:ro
        - ${CERT_DIR}:/certs:ro
  EOF

  echo "[+] Reload hook for cert renewals"
  cat > /usr/local/bin/reload-web.sh <<'EOF'
  #!/bin/bash
  set -e
  if docker ps --format "{{.Names}}" | grep -qx wp2-nginx; then
    docker kill -s HUP wp2-nginx >/dev/null 2>&1 || docker restart wp2-
  nginx >/dev/null 2>&1 || true
  fi
  if docker ps --format "{{.Names}}" | grep -qx hysteria2; then
    docker restart hysteria2 >/dev/null 2>&1 || true
  fi
  EOF
  chmod +x /usr/local/bin/reload-web.sh

  echo "[+] acme.sh issue/install cert"
  if [ ! -x "$HOME/.acme.sh/acme.sh" ]; then
    curl -fsSL https://get.acme.sh | sh -s email=${EMAIL}
  fi
  export PATH="$HOME/.acme.sh:$PATH"
  mkdir -p "${CERT_DIR}"
  ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null
  ~/.acme.sh/acme.sh --issue --webroot "${SITE_DIR}" -d "${DOMAIN}"
  --keylength ec-256 --force
  ~/.acme.sh/acme.sh --install-cert -d "${DOMAIN}" --ecc \
    --key-file "${CERT_DIR}/${DOMAIN}.key" \
    --fullchain-file "${CERT_DIR}/fullchain.cer" \
    --reloadcmd "/usr/local/bin/reload-web.sh"

  echo "[+] Start stack"
  cd "${CONF_DIR}"
  docker compose up -d --force-recreate

  echo "[+] Done. Hysteria2 link:"
  echo "hysteria2://${HYST_PASS}@${DOMAIN}:443?insecure=0&sni=${DOMAIN}
  #wp2-ursoftware"