#!/usr/bin/env bash
# Gift Links — one-shot installer for an Ubuntu droplet with nginx.
# Run as root:   bash <(curl -fsSL https://raw.githubusercontent.com/nikadevs/gift-links/main/install.sh)
# Safe to re-run (updates code, keeps .env and database).
set -euo pipefail

DOMAIN="giftlinks.nikadevs.com"
APP_DIR="/opt/gift-links"
PORT="3107"
TARBALL="https://raw.githubusercontent.com/nikadevs/gift-links/main/gift-links.tar.gz"

say() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*"; exit 1; }

[ "$(id -u)" = "0" ] || die "run as root (sudo -i first)"
command -v nginx >/dev/null || die "nginx not found"

# ---------- swap (1 GB droplets need it for npm) ----------
if ! swapon --show | grep -q .; then
  say "Adding 2G swap file"
  fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# ---------- Node 22 ----------
NODE_MAJOR=$(node -v 2>/dev/null | sed 's/v\([0-9]*\).*/\1/' || echo 0)
if [ "${NODE_MAJOR:-0}" -lt 22 ]; then
  say "Installing Node.js 22"
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
  apt-get install -y nodejs
fi
command -v pm2 >/dev/null || { say "Installing pm2"; npm i -g pm2; }

# ---------- code ----------
say "Downloading app code"
TMP=$(mktemp -d)
curl -fsSL "$TARBALL" -o "$TMP/app.tgz"
tar -xzf "$TMP/app.tgz" -C "$TMP"
mkdir -p "$APP_DIR"
# keep secrets, database and linked Shopify config between updates
for keep in .env prisma/dev.sqlite shopify.app.toml shopify.app.*.toml; do
  [ -e "$APP_DIR/$keep" ] && mkdir -p "$TMP/keep/$(dirname "$keep")" && cp -a "$APP_DIR/$keep" "$TMP/keep/$keep" || true
done
rm -rf "$APP_DIR.new" && mv "$TMP/gift-links" "$APP_DIR.new"
[ -d "$TMP/keep" ] && cp -a "$TMP/keep/." "$APP_DIR.new/"
rm -rf "$APP_DIR.old"; [ -d "$APP_DIR" ] && mv "$APP_DIR" "$APP_DIR.old"
mv "$APP_DIR.new" "$APP_DIR"
rm -rf "$TMP"
cd "$APP_DIR"

say "Installing dependencies (a few minutes)"
npm ci --no-audit --no-fund
npm run setup

# ---------- Shopify app (interactive the first time) ----------
if ! grep -qs '^client_id = "[^"]\+"' shopify.app*.toml; then
  say "Connect to Shopify: choose 'Create a new app', name it Gift Links. Open the login link it prints."
  npx shopify app config link
fi
CFG=$(grep -ls '^client_id = "[^"]\+"' shopify.app*.toml | head -1)
[ -n "$CFG" ] || die "Shopify app is not linked"
sed -i -E "s#^application_url = .*#application_url = \"https://$DOMAIN\"#" "$CFG"
if grep -q '^redirect_urls' "$CFG"; then
  sed -i -E "s#^redirect_urls = .*#redirect_urls = [ \"https://$DOMAIN/auth/callback\", \"https://$DOMAIN/auth/shopify/callback\", \"https://$DOMAIN/api/auth/callback\" ]#" "$CFG"
else
  printf '\n[auth]\nredirect_urls = [ "https://%s/auth/callback", "https://%s/auth/shopify/callback", "https://%s/api/auth/callback" ]\n' "$DOMAIN" "$DOMAIN" "$DOMAIN" >> "$CFG"
fi

say "Deploying app config + theme app embed to Shopify"
npx shopify app deploy --force

say "Writing .env"
npx shopify app env pull --env-file .env
sed -i '/^SHOPIFY_APP_URL=/d;/^PORT=/d;/^NODE_ENV=/d' .env
printf 'SHOPIFY_APP_URL=https://%s\nPORT=%s\nNODE_ENV=production\n' "$DOMAIN" "$PORT" >> .env
chmod 600 .env

# ---------- run ----------
say "Starting app with pm2 on port $PORT"
cat > ecosystem.config.cjs <<EOF
module.exports = { apps: [{
  name: "gift-links",
  cwd: "$APP_DIR",
  script: "./node_modules/@react-router/serve/bin.js",
  args: "./build/server/index.js",
  node_args: "--env-file=.env",
  env: { NODE_ENV: "production", PORT: "$PORT" }
}] };
EOF
[ -f ./node_modules/@react-router/serve/bin.js ] || sed -i 's#./node_modules/@react-router/serve/bin.js#./node_modules/.bin/react-router-serve#' ecosystem.config.cjs
pm2 delete gift-links >/dev/null 2>&1 || true
pm2 start ecosystem.config.cjs
pm2 save
pm2 startup systemd -u root --hp /root >/dev/null 2>&1 || true
sleep 3
curl -fsS -o /dev/null "http://127.0.0.1:$PORT/" && echo "app responds on :$PORT" || die "app did not start — run: pm2 logs gift-links"

# ---------- nginx + SSL (only this subdomain) ----------
SITE=/etc/nginx/sites-available/gift-links
if [ ! -f "$SITE" ]; then
  say "Adding nginx site for $DOMAIN"
  cat > "$SITE" <<EOF
server {
    listen 80;
    server_name $DOMAIN;
    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
EOF
  ln -sf "$SITE" /etc/nginx/sites-enabled/gift-links
fi
nginx -t && systemctl reload nginx

if [ ! -d "/etc/letsencrypt/live/$DOMAIN" ]; then
  say "Getting SSL certificate"
  command -v certbot >/dev/null || apt-get install -y certbot python3-certbot-nginx
  certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email --redirect
fi

say "DONE ✅  https://$DOMAIN is live."
echo "Next: install the app in your store (Dev Dashboard → Gift Links → Distribution / Install) and turn on the app embed in your theme."
