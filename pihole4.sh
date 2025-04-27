#!/bin/bash

# Prompt the user for the DNS address, network interface, and Pi-hole admin password
read -p "Enter the DNS address for your Pi-hole (e.g., dns.example.com): " DNS_ADDRESS
read -p "Enter the network interface for Pi-hole (e.g., eth0): " INTERFACE
read -s -p "Enter the Pi-hole admin password: " ADMIN_PASSWORD
echo

# Update system packages
sudo apt update
sudo apt upgrade -y

# Set environment variables to avoid prompts during package installation
export DEBIAN_FRONTEND=noninteractive
echo '* libraries/restart-without-asking boolean true' | sudo debconf-set-selections

# Create the Pi-hole directory if it doesn't exist
sudo mkdir -p /etc/pihole

# Install Nginx and dependencies
sudo apt install -y nginx-full curl php8.1-fpm php8.1-cgi php8.1-xml php8.1-sqlite3 php8.1-intl apache2-utils certbot python3-certbot-nginx python3-certbot-dns-cloudflare

# Create setupVars.conf file with necessary configurations
sudo tee /etc/pihole/setupVars.conf > /dev/null <<EOL
PIHOLE_INTERFACE=$INTERFACE
IPV4_ADDRESS=$(hostname -I | awk '{print $1}')
IPV6_ADDRESS=$(hostname -I | awk '{print $2}')
PIHOLE_DNS_1=1.1.1.1
PIHOLE_DNS_2=1.0.0.1
QUERY_LOGGING=true
INSTALL_WEB_SERVER=true
INSTALL_WEB_INTERFACE=true
LIGHTTPD_ENABLED=false
EOL

# Install Pi-hole without user input using setupVars.conf
curl -sSL https://install.pi-hole.net | bash /dev/stdin --unattended

# Set the Pi-hole admin password properly
sudo pihole -a -p "$ADMIN_PASSWORD"

# Stop and disable Lighttpd only if installed
if systemctl list-units --type=service | grep -q "lighttpd"; then
    sudo systemctl stop lighttpd
    sudo systemctl disable lighttpd
fi

# Check if credentials.ini exists
if [ ! -f /opt/pihole/credentials.ini ]; then
  # Obtain SSL certificate using DNS-01 challenge with Cloudflare DNS plugin
  read -s -p "Enter your Cloudflare API Key: " CLOUDFLARE_API_Key
  echo
  read -s -p "Enter your Cloudflare Email: " CLOUDFLARE_Email
  echo
  read -s -p "Enter Email for SSL Cert: " CERTBOT_Email
  echo

  # Create credentials.ini
  sudo tee /opt/pihole/credentials.ini > /dev/null <<EOL
dns_cloudflare_api_key = $CLOUDFLARE_API_Key
dns_cloudflare_email = $CLOUDFLARE_Email
dns_certbot_email = $CERTBOT_Email
EOL

  echo "Created /opt/pihole/credentials.ini"
else
  echo "/opt/pihole/credentials.ini already exists, skipping credential creation."
fi

# Fix permisisons on created file
sudo chmod -R 755 /opt/pihole/credentials.ini

# Run Certbot with DNS-01 challenge to obtain the certificate
sudo certbot certonly \
  --dns-cloudflare \
  --dns-cloudflare-credentials /opt/pihole/credentials.ini \
  --email "$CERTBOT_Email" \
  --agree-tos \
  --non-interactive \
  -d "$DNS_ADDRESS"

# Configure Nginx for HTTP and HTTPS
sudo tee /etc/nginx/sites-available/default > /dev/null <<EOL
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name $DNS_ADDRESS;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;
    server_name $DNS_ADDRESS;

    ssl_certificate /etc/letsencrypt/live/$DNS_ADDRESS/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DNS_ADDRESS/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    root /var/www/html;
    index index.php index.html index.htm;

    location /admin {
        root /var/www/html;
        index index.php index.html index.htm;
    }

    location ~ ^/admin/(.*\.php)$ {
        root /var/www/html;
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/php8.1-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
    }

    location / {
        expires max;
        try_files \$uri \$uri/ =404;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOL

# Adjust permissions
sudo chown -R www-data:www-data /var/www/html
sudo chmod -R 755 /var/www/html
sudo usermod -aG pihole www-data

# Create Nginx stream directory if not exists
sudo mkdir -p /etc/nginx/streams/

# Create DNS over TLS configuration
sudo tee /etc/nginx/streams/dns-over-tls > /dev/null <<EOL
upstream dns-servers {
    server 127.0.0.1:53;
    server [::1]:53;
}
server {
    listen [::]:853 ssl;
    listen 853 ssl;
    ssl_certificate /etc/letsencrypt/live/$DNS_ADDRESS/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DNS_ADDRESS/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    ssl_handshake_timeout 10s;
    ssl_session_cache shared:SSL:20m;
    ssl_session_timeout 4h;
    proxy_pass dns-servers;
}
EOL

# Update nginx.conf to include stream
if ! grep -q "include /etc/nginx/streams/*;" /etc/nginx/nginx.conf; then
sudo tee -a /etc/nginx/nginx.conf > /dev/null <<EOL
stream {
    include /etc/nginx/streams/*;
}
EOL
fi

# Restart services
sudo systemctl restart php8.1-fpm
sudo systemctl restart nginx
sudo systemctl restart pihole-FTL

# Enable services on boot
sudo systemctl enable php8.1-fpm
sudo systemctl enable nginx

# Set up a cron job for automatic certificate renewal
(crontab -l 2>/dev/null; echo "0 3 * * * /usr/bin/certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -

echo "Pi-hole with Nginx, SSL (Certbot), DNS over TLS, and HTTPS on port 443 setup completed!"
