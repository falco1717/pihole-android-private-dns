#!/bin/bash

# Prompt the user for the DNS address, network interface, and Pi-hole admin password
read -p "Enter the DNS address for your Pi-hole (e.g., dns.example.com): " DNS_ADDRESS
read -p "Enter the network interface for Pi-hole (e.g., eth0): " INTERFACE
read -s -p "Enter the Pi-hole admin password: " ADMIN_PASSWORD
echo

# Set environment variables to avoid prompts during package installation
export DEBIAN_FRONTEND=noninteractive
echo '* libraries/restart-without-asking boolean true' | sudo debconf-set-selections

# Create the Pi-hole directory if it doesn't exist
sudo mkdir -p /etc/pihole

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

# Update and install necessary packages without prompts
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y curl nginx php8.1-fpm php8.1-cgi php8.1-xml php8.1-sqlite3 php8.1-intl apache2-utils certbot python3-certbot-nginx

# Install Pi-hole without user input using setupVars.conf
curl -sSL https://install.pi-hole.net | bash /dev/stdin --unattended

# Set the Pi-hole admin password
sudo pihole -a -p "$ADMIN_PASSWORD"

# Stop and disable Lighttpd
sudo systemctl stop lighttpd
sudo systemctl disable lighttpd

# Obtain SSL certificate without prompting for terms of service or email sharing
sudo certbot certonly --nginx -d $DNS_ADDRESS --agree-tos --register-unsafely-without-email

# Configure Nginx for HTTP and HTTPS
sudo tee /etc/nginx/sites-available/default > /dev/null <<EOL
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name $DNS_ADDRESS;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name $DNS_ADDRESS;
    root /var/www/html;

    ssl_certificate /etc/letsencrypt/live/$DNS_ADDRESS/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DNS_ADDRESS/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    autoindex off;
    index pihole/index.php index.php index.html index.htm;

    location / {
        expires max;
        try_files \$uri \$uri/ =404;
    }

    location ~ \.php\$ {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_pass unix:/run/php/php8.1-fpm.sock;
        fastcgi_param FQDN true;
    }

    location /*.js {
        index pihole/index.js;
    }

    location /admin {
        root /var/www/html;
        index index.php index.html index.htm;
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
if [ ! -d "/etc/nginx/streams/" ]; then
  sudo mkdir /etc/nginx/streams/
fi

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
sudo tee -a /etc/nginx/nginx.conf > /dev/null <<EOL
stream {
    include /etc/nginx/streams/*;
}
EOL

# Restart Nginx to apply changes
sudo systemctl restart nginx

# Enable and start services
sudo systemctl enable php8.1-fpm
sudo systemctl start php8.1-fpm
sudo systemctl enable nginx
sudo systemctl start nginx

# Configure Pi-hole to use local DNS resolver
sudo tee /etc/dnsmasq.d/01-pihole.conf > /dev/null <<EOL
server=127.0.0.1#53
EOL

# Restart Pi-hole DNS service
sudo systemctl restart pihole-FTL

# Set up a cron job for automatic certificate renewal
(crontab -l 2>/dev/null; echo "0 3 * * * /usr/bin/certbot renew --quiet --post-hook 'systemctl reload nginx'") | crontab -

echo "Pi-hole with Nginx, SSL, DNS over TLS, and HTTPS on port 443 setup completed!"
