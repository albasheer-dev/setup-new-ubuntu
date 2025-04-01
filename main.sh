#!/bin/bash
LOG_FILE="/var/log/setup_script.log"
exec > >(tee -a "$LOG_FILE") 2>&1
# Variables to store user input
SUDO_USERNAME=""
USERNAME=""
DOMAIN_NAME=""
PHP_VERSION=""
MARIADB_VERSION=""

# Function to request parameters
request_parameter() {
    local var_name=$1
    local prompt_message=$2
    local current_value=${!var_name}

    if [ -z "$current_value" ]; then
        read -p "$prompt_message: " user_input
        eval "$var_name=\"$user_input\""
    else
        echo "$var_name is already set to $current_value, skipping input." >&2
    fi
}

create_user_with_ssh() {
    request_parameter "SUDO_USERNAME" "Enter username"

    echo "Creating user account: $SUDO_USERNAME" >&2
    sudo adduser --quiet --disabled-password --gecos "" $SUDO_USERNAME
    sudo usermod -aG sudo $SUDO_USERNAME
    echo "User $SUDO_USERNAME created and added to sudo group."

    # إعداد مجلد .ssh مع الصلاحيات الصحيحة
    sudo mkdir -p /home/$SUDO_USERNAME/.ssh
    sudo chmod 700 /home/$SUDO_USERNAME/.ssh

    # إنشاء ملف authorized_keys مع الصلاحيات الصحيحة
    sudo touch /home/$SUDO_USERNAME/.ssh/authorized_keys
    sudo chmod 600 /home/$SUDO_USERNAME/.ssh/authorized_keys

    # تغيير ملكية المجلد والملفات إلى المستخدم الجديد
    sudo chown -R $SUDO_USERNAME:$SUDO_USERNAME /home/$SUDO_USERNAME/.ssh

    # طلب مفتاح SSH من المستخدم وإضافته إلى authorized_keys
    read -p "Paste the SSH Public Key for $SUDO_USERNAME: " SSH_KEY
    echo "$SSH_KEY" | sudo tee -a /home/$SUDO_USERNAME/.ssh/authorized_keys > /dev/null

    echo "SSH key added for $SUDO_USERNAME."
    echo "Now you can log in as: ssh $SUDO_USERNAME@<server-ip>"

    # تعطيل تسجيل الدخول بالروت
    echo "Disabling root login..."
    sudo sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config

    # تعطيل تسجيل الدخول بكلمة المرور
    echo "Disabling password authentication..."
    sudo sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sudo sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config

    # إعادة تشغيل SSH لتطبيق التغييرات
    echo "Restarting SSH service..."
    sudo systemctl restart ssh

    echo "Setup complete. Root login and password authentication are disabled."
}


# Function to create a user
create_user() {
    request_parameter "USERNAME" "Enter username"
    echo "Creating user account: $USERNAME" >&2
    sudo adduser --quiet $USERNAME
    echo "Granting sudo privileges to $USERNAME" >&2
    sudo usermod -aG sudo $USERNAME
}


# Function to create a user folders
create_user_folders() {
    request_parameter "USERNAME" "Enter username"
    echo "Creating public_html directory for $USERNAME" >&2
    sudo mkdir -p "/home/$USERNAME/public_html"
    echo "Setting permissions for user home and public_html" >&2
    sudo chmod 711 "/home/$USERNAME"
    sudo chmod 755 "/home/$USERNAME/public_html"
    sudo chown $USERNAME:$USERNAME "/home/$USERNAME/public_html"
}

# Function to install Apache
install_apache() {
    echo "Installing Apache..." >&2
    sudo apt update && sudo apt upgrade -y
    sudo apt install -y apache2

    echo "Enabling necessary Apache modules..." >&2
    sudo a2enmod rewrite userdir proxy proxy_fcgi
    echo "Apache modules enabled: rewrite, userdir, proxy, proxy_fcgi" >&2

    # تعديل userdir.conf
    USERDIR_CONF="/etc/apache2/mods-enabled/userdir.conf"
    if [ -f "$USERDIR_CONF" ]; then
        echo "Editing $USERDIR_CONF..." >&2
        sudo sed -i 's/UserDir disabled/UserDir public_html/' "$USERDIR_CONF"
        sudo sed -i '/<Directory \/home\/*\/public_html>/,/<\/Directory>/c\<Directory /home/*/public_html>\n    AllowOverride All\n    Options Indexes FollowSymLinks\n    Require all granted\n</Directory>' "$USERDIR_CONF"
    else
        echo "$USERDIR_CONF not found! Skipping..." >&2
    fi

    sudo systemctl restart apache2
}

create_new_domain() {
    # إعداد Virtual Host للمستخدم
    request_parameter "USERNAME" "Enter username"
    request_parameter "DOMAIN_NAME" "Enter domain name"
    request_parameter "PHP_VERSION" "Enter PHP version"

    USER_HOME="/home/$USERNAME"

    # Prompt to determine DocumentRoot path
    read -p "Do you want to use the default 'public_html' or add a custom subpath? [default/custom]: " PATH_CHOICE
    if [ "$PATH_CHOICE" == "custom" ]; then
        read -p "Enter the custom subpath inside 'public_html' (e.g., 'subfolder'): " SUBPATH
        PUBLIC_HTML="$USER_HOME/public_html/$SUBPATH"
    else
        PUBLIC_HTML="$USER_HOME/public_html"
    fi

    USER_VHOST_CONF="/etc/apache2/sites-available/$DOMAIN_NAME.conf"

    # Get the domain root
    DOMAIN_ROOT=$(get_domain_root "$DOMAIN_NAME")

    if [ ! -f "$USER_VHOST_CONF" ]; then
        echo "Creating virtual host configuration for $USERNAME..." >&2
        sudo bash -c "cat > $USER_VHOST_CONF" <<EOL
<VirtualHost *:80>
    ServerName $DOMAIN_NAME
EOL

        # Add ServerAlias if the domain is not a subdomain
        if [ "$DOMAIN_NAME" == "$DOMAIN_ROOT" ]; then
            echo "    ServerAlias www.$DOMAIN_NAME" | sudo tee -a "$USER_VHOST_CONF" >&2
        fi

        sudo bash -c "cat >> $USER_VHOST_CONF" <<EOL
    DocumentRoot $PUBLIC_HTML

    <Directory $PUBLIC_HTML>
        AllowOverride All
        Options Indexes FollowSymLinks
        Require all granted
    </Directory>

    <FilesMatch \.php$>
        SetHandler "proxy:unix:/run/php/php$PHP_VERSION-fpm-$USERNAME.sock|fcgi://localhost/"
    </FilesMatch>

    ErrorLog $USER_HOME/error.log
    CustomLog $USER_HOME/access.log combined
</VirtualHost>
EOL
    else
        echo "$USER_VHOST_CONF already exists! Skipping..." >&2
    fi

    echo "Enabling the virtual host for $DOMAIN_NAME and restarting Apache..." >&2
    sudo a2ensite "$DOMAIN_NAME.conf"
    sudo systemctl restart apache2

    read -p "Do you want to configure an SSL certificate for this domain? [yes/no]: " SSL_CHOICE
    if [ "$SSL_CHOICE" == "yes" ]; then
        ssl_cert "$DOMAIN_NAME"
    else
        echo "Skipping SSL certificate configuration." >&2
    fi
}

get_domain_root() {
    # Function to determine the root domain from a given domain name
    local domain_name=$1
    echo "$domain_name" | awk -F. '{if (NF>2) print $(NF-1)"."$NF; else print $0}'
}

ssl_cert() {
    local domain_name=$1
    DOMAIN_ROOT=$(get_domain_root "$domain_name")

    # Test Apache configuration
    echo "Testing Apache configuration..." >&2
    if ! sudo apache2ctl configtest; then
        echo "Apache configuration test failed. Exiting the function." >&2
        return 1  # Exit the function with an error code
    fi

    echo "Installing Certbot if not installed..."
    if ! command -v certbot &> /dev/null; then
        if ! sudo apt update; then
            echo "Failed to update package list. Exiting." >&2
            exit 1
        fi
        sudo apt install -y certbot python3-certbot-apache
    fi

    # Generate SSL certificate
    if [ "$domain_name" == "$DOMAIN_ROOT" ]; then
        if ! sudo certbot --apache -d "$domain_name" -d "www.$domain_name"; then
            echo "SSL certificate generation failed for $domain_name." >&2
            return 1
        fi
    else
        if ! sudo certbot --apache -d "$domain_name"; then
            echo "SSL certificate generation failed for $domain_name." >&2
            return 1
        fi
    fi

    # Restart Apache
    sudo systemctl restart apache2
}


# Function to install PHP
install_php() {
    request_parameter "PHP_VERSION" "Enter PHP version"
    request_parameter "USERNAME" "Enter username"

    USER_HOME="/home/$USERNAME"
    PHP_POOL_CONF="/etc/php/$PHP_VERSION/fpm/pool.d/$USERNAME.conf"

    echo "Installing PHP version $PHP_VERSION..." >&2
    sudo apt install -y software-properties-common
    sudo add-apt-repository ppa:ondrej/php -y
    if ! sudo apt update; then
        echo "Failed to update package list. Exiting." >&2
        exit 1
    fi
    sudo apt install php$PHP_VERSION php$PHP_VERSION-fpm php$PHP_VERSION-bz2 libapache2-mod-php$PHP_VERSION php$PHP_VERSION-cli php$PHP_VERSION-curl php$PHP_VERSION-gd php$PHP_VERSION-intl php$PHP_VERSION-mbstring php$PHP_VERSION-mysql php$PHP_VERSION-protobuf php$PHP_VERSION-sqlite3 php$PHP_VERSION-xml php$PHP_VERSION-zip php$PHP_VERSION-zstd -y
    sudo a2enmod php$PHP_VERSION
    sudo update-alternatives --set php /usr/bin/php$PHP_VERSION


    # إنشاء ملف pool للمستخدم
    if [ ! -f "$PHP_POOL_CONF" ]; then
        echo "Creating PHP-FPM pool configuration for $USERNAME..." >&2
        sudo bash -c "cat > $PHP_POOL_CONF" <<EOL
[$USERNAME]
user = $USERNAME
group = $USERNAME
listen = /run/php/php$PHP_VERSION-fpm-$USERNAME.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = ondemand
pm.max_children = 5
pm.process_idle_timeout = 10s
pm.max_requests = 200
chdir = $USER_HOME
EOL
    else
        echo "$PHP_POOL_CONF already exists! Skipping..." >&2
    fi

    echo "Restarting PHP-FPM services..." >&2
    sudo systemctl restart php$PHP_VERSION-fpm
}

disable_default_site() {
    sudo a2dissite 000-default.conf
}

# Function to install Node.js
install_node() {
    echo "Select the Node.js version you want to install (e.g., 18, 20):" >&2
    read -p "Enter Node.js version: " NODE_VERSION
    echo "Installing Node.js version $NODE_VERSION..." >&2
    curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | sudo -E bash -
    sudo apt install -y nodejs
    echo "Node.js and npm versions installed:" >&2
    node -v
    npm -v
}

# Function to install MariaDB
install_mariadb() {
curl -fsSL https://mariadb.org/mariadb_release_signing_key.asc | sudo tee /etc/apt/trusted.gpg.d/mariadb.asc

    request_parameter "MARIADB_VERSION" "Enter MariaDB version"
    echo "Installing MariaDB version $MARIADB_VERSION..." >&2
    sudo apt install software-properties-common -y
    sudo apt install -y gnupg
    sudo wget "https://mariadb.org/mariadb-release.org/mariadb-$MARIADB_VERSION-repo.gpg" -O /etc/apt/trusted.gpg.d/mariadb.gpg
    sudo wget "https://downloads.mariadb.com/MariaDB/mariadb-$MARIADB_VERSION/repo/ubuntu/mariadb-$MARIADB_VERSION.list" -O "/etc/apt/sources.list.d/mariadb-$MARIADB_VERSION.list"

    # sudo apt-key adv --fetch-keys 'https://mariadb.org/mariadb_release_signing_key.asc'
    # sudo add-apt-repository "deb http://mirror.i3d.net/pub/mariadb/repo/$MARIADB_VERSION/ubuntu $(lsb_release -cs) main" -y
    if ! sudo apt update; then
        echo "Failed to update package list. Exiting." >&2
        exit 1
    fi
    sudo apt install -y mariadb-server mariadb-client
    sudo systemctl start mariadb
    sudo systemctl enable mariadb
    sudo mysql_secure_installation
    echo "MariaDB installed and secured."
}

# Function to install Composer
install_composer() {
    echo "install the following packages (composer dependencies)" >&2
    sudo apt install gzip tar unrar unzip -y
    echo "Installing Composer..." >&2
    sudo php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    sudo php -r "if (hash_file('sha384', 'dac665fdc30fdd8ec78b38b9800061b4150413ff2e3b6f88543c636f7cd84f6db9189d43a81e5503cda447da73c7e5b6') { echo 'Installer verified'; } else { echo 'Installer corrupt'; unlink('composer-setup.php'); } echo PHP_EOL;"
    sudo php composer-setup.php
    sudo php -r "unlink('composer-setup.php');"
    sudo mv composer.phar /usr/local/bin/composer
    echo "Composer installed successfully." >&2
}

# Function to install Jenkins
install_jenkins() {
    echo "Installing Jenkins..." >&2
    sudo wget -O /usr/share/keyrings/jenkins-keyring.asc https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key
    echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" | sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null
    if ! sudo apt update; then
        echo "Failed to update package list. Exiting." >&2
        exit 1
    fi
    sudo apt install -y jenkins
    echo "Installing Java..." >&2
    sudo apt install -y fontconfig openjdk-17-jre
    java -version
    sudo systemctl enable jenkins
    sudo systemctl start jenkins
    echo "Fetching Jenkins initial admin password..." >&2
    sudo cat /var/lib/jenkins/secrets/initialAdminPassword
    echo -e "\nUse this password to complete Jenkins setup in your browser."
}

system_cleanup() {
    echo "Cleaning up the system..." >&2
    sudo apt autoremove -y
    sudo apt autoclean
    echo "System cleanup complete." >&2
}

configure_firewall() {
    echo "Configuring UFW firewall..."
    sudo ufw allow OpenSSH
    sudo ufw enable
    sudo ufw allow https
    echo "Firewall configured successfully."
}

install_fail2ban() {
    sudo apt install fail2ban -y
    sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
        # sudo nano jail.local
        # sudo systemctl enable fail2ban
        # sudo systemctl start fail2ban

    # To list all banned IPs across all active jails, use:
        # sudo fail2ban-client banned
        # sudo fail2ban-client status
        # sudo fail2ban-client status sshd
}

auto_renew_cert() {
    # Check if UFW is active
    if sudo ufw status | grep -q "Status: active"; then
        echo "UFW is active. Configuring rules..."
        sudo ufw allow http
        sudo ufw allow https
        sudo ufw reload
    else
        echo "UFW is not active. Skipping firewall configuration."
    fi

    # Ensure cronjobs.sh has execution permission
    sudo chmod +x ./cronjobs.sh

    # Start cronjobs.sh to handle all SSL renewals
    /bin/bash ./cronjobs.sh
}


# Main script logic
echo "Updating and upgrading the system..."
sudo apt update && sudo apt upgrade -y

echo "Welcome! Please select the steps you'd like to perform."

read -p "Do you want to create a sudo user ? (yes/no): " DO_USER
if [[ "$DO_USER" == "yes" ]]; then
    create_user_with_ssh
fi

read -p "Do you want to create a user and set up directories? (yes/no): " DO_USER_PATH
if [[ "$DO_USER_PATH" == "yes" ]]; then
    create_user
    create_user_folders
fi

read -p "Do you want to install Apache? (yes/no): " DO_APACHE
if [[ "$DO_APACHE" == "yes" ]]; then
    install_apache
fi

read -p "Do you want to disable apache default site? (yes/no): " DO_DISABLE_APACHE_DEFAULT_SITE
if [[ "$DO_DISABLE_APACHE_DEFAULT_SITE" == "yes" ]]; then
    disable_default_site
fi

read -p "Do you want to create new domain? (yes/no): " DO_CREATE_NEW_DOMAIN
if [[ "$DO_CREATE_NEW_DOMAIN" == "yes" ]]; then
    create_new_domain
fi

read -p "Do you want to configure an SSL certificate for custom domain? [yes/no]: " SSL_CHOICE_2
if [ "$SSL_CHOICE_2" == "yes" ]; then
    read -p "Enter your coustom domain name !" CUSTOM_DOMAIN_NAME
    ssl_cert "$CUSTOM_DOMAIN_NAME"
fi

read -p "Do you want to renew a SSL certificate for domains? [yes/no]: " DO_RENEW_DOMAIN
if [[ "$DO_RENEW_DOMAIN" == "yes" ]]; then
    auto_renew_cert
fi

read -p "Do you want to install PHP? (yes/no): " DO_PHP
if [[ "$DO_PHP" == "yes" ]]; then
    install_php
fi

read -p "Do you want to install Node.js? (yes/no): " DO_NODE
if [[ "$DO_NODE" == "yes" ]]; then
    install_node
fi

read -p "Do you want to install MariaDB? (yes/no): " DO_MARIADB
if [[ "$DO_MARIADB" == "yes" ]]; then
    install_mariadb
fi

read -p "Do you want to install Composer? (yes/no): " DO_COMPOSER
if [[ "$DO_COMPOSER" == "yes" ]]; then
    install_composer
fi

read -p "Do you want to install Jenkins? (yes/no): " DO_JENKINS
if [[ "$DO_JENKINS" == "yes" ]]; then
    install_jenkins
fi

read -p "Do you want to perform a system cleanup? (yes/no): " DO_CLEANUP
if [[ "$DO_CLEANUP" == "yes" ]]; then
    system_cleanup
fi

read -p "Do you want to configure the firewall? (yes/no): " DO_FIREWALL
if [[ "$DO_FIREWALL" == "yes" ]]; then
    configure_firewall
fi

sudo ufw deny http
echo "Setup complete. Thank you!" 


# this is in .htaccess in the same public_html
# <IfModule mod_rewrite.c>
#   RewriteEngine On

  # Allow only specified domains
  # RewriteCond %{HTTP_HOST} !^albasheer\.dev$ [NC]
  # RewriteCond %{HTTP_HOST} !^www\.albasheer\.dev$ [NC]
  # RewriteCond %{HTTP_HOST} !^sub\.albasheer\.dev$ [NC]
  # RewriteCond %{HTTP_HOST} !^www\.sub\.albasheer\.dev$ [NC]
  # RewriteRule ^ - [F]

  # Set default index files
#   DirectoryIndex index.php index.html
# </IfModule>

# to use this file 
# chmod +x setup_server.sh
# ./setup_server.sh

# sudo apt install htop -y

# rsync -avz --progress /home/username/ user@new_server:/home/username/ 

# mysqldump -u root -p database_name > database_name.sql
# scp database_name.sql user@new_server:/path/to/destination
# mysql -u root -p database_name < database_name.sql

# https://patorjk.com/software/taag/ for ascii art
# sudo nano /etc/motd
# sudo nano /etc/hostname
# sudo nano /etc/hosts
# hostnamectl
# sudo reboot

# sql 
# CREATE USER 'new_user'@'localhost' IDENTIFIED BY 'password';
# GRANT ALL PRIVILEGES ON mydatabase.* TO 'new_user'@'localhost';
# FLUSH PRIVILEGES;
