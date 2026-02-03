#!/bin/bash
set -e

echo "===================================="
echo " OBSIDIAN FULL AUTO SETUP STARTED"
echo "===================================="

read -p "Domain (example: sync.yourdomain.com): " DOMAIN
read -p "CouchDB Admin Username: " COUCH_USER
read -s -p "CouchDB Admin Password: " COUCH_PASS
echo
read -p "GitHub Username: " GH_USER
read -p "GitHub Repo Name (example: obsidian-backup): " GH_REPO
read -s -p "Backup Encryption Password: " BACKUP_PASS
echo
read -p "Email for Let's Encrypt: " EMAIL

DATA_DIR="/opt/obsidian-couchdb/data"
BACKUP_DIR="/opt/obsidian-backup"

echo "[1/8] System update"
apt update -y && apt upgrade -y

echo "[2/8] Install base packages"
apt install -y ca-certificates curl gnupg lsb-release git ufw nginx certbot python3-certbot-nginx

echo "[3/8] Install Docker"
mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" > /etc/apt/sources.list.d/docker.list
apt update -y
apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable docker
systemctl start docker

echo "[4/8] Setup CouchDB (Docker)"
mkdir -p $DATA_DIR
chown -R 1000:1000 /opt/obsidian-couchdb

cat > /opt/obsidian-couchdb/docker-compose.yml <<EOF
version: "3.8"
services:
  couchdb:
    image: couchdb:3
    container_name: obsidian-couchdb
    restart: unless-stopped
    environment:
      - COUCHDB_USER=$COUCH_USER
      - COUCHDB_PASSWORD=$COUCH_PASS
    ports:
      - "127.0.0.1:5984:5984"
    volumes:
      - $DATA_DIR:/opt/couchdb/data
EOF

cd /opt/obsidian-couchdb
docker compose up -d

echo "[5/8] Setup Firewall"
ufw allow OpenSSH
ufw allow 80
ufw allow 443
ufw --force enable

echo "[6/8] Setup Nginx + TLS"
cat > /etc/nginx/sites-available/couchdb <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:5984;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_buffering off;
    }
}
EOF

ln -s /etc/nginx/sites-available/couchdb /etc/nginx/sites-enabled/ || true
nginx -t
systemctl reload nginx

certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m $EMAIL --redirect

echo "[7/8] Setup GitHub Backup"
ssh-keygen -t ed25519 -C "obsidian-backup" -f /root/.ssh/id_ed25519 -N ""

echo "===================================="
echo " COPY THIS SSH KEY TO GITHUB"
echo "===================================="
cat /root/.ssh/id_ed25519.pub
echo "===================================="
read -p "Press ENTER after adding key to GitHub..."

cd /opt
git clone git@github.com:$GH_USER/$GH_REPO.git

cat > /opt/backup-github.sh <<EOF
#!/bin/bash
DATE=\$(date +"%Y-%m-%d_%H-%M")
DATA_DIR="$DATA_DIR"
BACKUP_DIR="$BACKUP_DIR"
PASSPHRASE="$BACKUP_PASS"

cd \$BACKUP_DIR || exit 1

tar -czf - \$DATA_DIR | openssl enc -aes-256-cbc -salt -out obsidian-\$DATE.tar.gz.enc -pass pass:\$PASSPHRASE

git add .
git commit -m "Encrypted backup \$DATE"
git push
EOF

chmod 700 /opt/backup-github.sh

echo "[8/8] Setup Daily Backup (3AM)"
(crontab -l 2>/dev/null; echo "0 3 * * * /opt/backup-github.sh >> /var/log/obsidian-backup.log 2>&1") | crontab -

echo "===================================="
echo " SETUP COMPLETE 🎉"
echo "===================================="
echo " CouchDB URL: https://$DOMAIN"
echo " Backup runs daily at 3AM"
echo " Log file: /var/log/obsidian-backup.log"
echo "===================================="
