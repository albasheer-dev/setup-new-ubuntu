#!/bin/bash

# Variables to store user input
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
        declare -g $var_name="$user_input"
    else
        echo "$var_name is already set to $current_value, skipping input."
    fi
}

# Function to create a user
create_user() {
    request_parameter "USERNAME" "Enter username"
    echo "Creating user account: $USERNAME"
    sudo adduser --quiet $USERNAME
    echo "Granting sudo privileges to $USERNAME"
    sudo usermod -aG sudo $USERNAME
    echo "Creating public_html directory for $USERNAME"
    sudo mkdir -p "/home/$USERNAME/public_html"
    echo "Setting permissions for user home and public_html"
    sudo chmod 755 "/home/$USERNAME"
    sudo chmod 755 "/home/$USERNAME/public_html"
    sudo chown $USERNAME:$USERNAME "/home/$USERNAME/public_html"
}

# Function to install Apache
install_apache() {
    echo "Installing Apache..."
    sudo apt update && sudo apt upgrade -y
    sudo apt install -y apache2

    echo "Enabling necessary Apache modules..."
    sudo a2enmod rewrite userdir proxy proxy_fcgi
    echo "Apache modules enabled: rewrite, userdir, proxy, proxy_fcgi"

    # تعديل userdir.conf
    USERDIR_CONF="/etc/apache2/mods-enabled/userdir.conf"
    if [ -f "$USERDIR_CONF" ]; then
        echo "Editing $USERDIR_CONF..."
        sudo sed -i 's/UserDir disabled/UserDir public_html/' "$USERDIR_CONF"
        sudo sed -i '/<Directory \/home\/*\/public_html>/,/<\/Directory>/c\<Directory /home/*/public_html>\n    AllowOverride All\n    Options Indexes FollowSymLinks\n    Require all granted\n</Directory>' "$USERDIR_CONF"
    else
        echo "$USERDIR_CONF not found! Skipping..."
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
        echo "Creating virtual host configuration for $USERNAME..."
        sudo bash -c "cat > $USER_VHOST_CONF" <<EOL
<VirtualHost *:80>
    ServerName $DOMAIN_NAME
EOL

        # Add ServerAlias if the domain is not a subdomain
        if [ "$DOMAIN_NAME" == "$DOMAIN_ROOT" ]; then
            echo "    ServerAlias www.$DOMAIN_NAME" | sudo tee -a "$USER_VHOST_CONF"
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
        echo "$USER_VHOST_CONF already exists! Skipping..."
    fi

    echo "Enabling the virtual host for $DOMAIN_NAME and restarting Apache..."
    sudo a2ensite "$DOMAIN_NAME.conf"
    sudo systemctl restart apache2

    read -p "Do you want to configure an SSL certificate for this domain? [yes/no]: " SSL_CHOICE
    if [ "$SSL_CHOICE" == "yes" ]; then
        ssl_cert "$DOMAIN_NAME"
    else
        echo "Skipping SSL certificate configuration."
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
    echo "Testing Apache configuration..."
    if ! sudo apache2ctl configtest; then
        echo "Apache configuration test failed. Exiting the function."
        return 1  # Exit the function with an error code
    fi

    # Install Certbot if not installed
    sudo apt update
    sudo apt install -y certbot python3-certbot-apache

    # Generate SSL certificate
    if [ "$domain_name" == "$DOMAIN_ROOT" ]; then
        sudo certbot --apache -d "$domain_name" -d "www.$domain_name"
    else
        sudo certbot --apache -d "$domain_name"
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

    echo "Installing PHP version $PHP_VERSION..."
    sudo apt install -y software-properties-common
    sudo add-apt-repository ppa:ondrej/php -y
    sudo apt update
    sudo apt install php$PHP_VERSION php$PHP_VERSION-fpm php$PHP_VERSION-bz2 libapache2-mod-php$PHP_VERSION php$PHP_VERSION-cli php$PHP_VERSION-curl php$PHP_VERSION-gd php$PHP_VERSION-intl php$PHP_VERSION-mbstring php$PHP_VERSION-mysql php$PHP_VERSION-protobuf php$PHP_VERSION-sqlite3 php$PHP_VERSION-xml php$PHP_VERSION-zip php$PHP_VERSION-zstd -y
    sudo a2enmod php$PHP_VERSION
    sudo update-alternatives --set php /usr/bin/php$PHP_VERSION


    # إنشاء ملف pool للمستخدم
    if [ ! -f "$PHP_POOL_CONF" ]; then
        echo "Creating PHP-FPM pool configuration for $USERNAME..."
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
        echo "$PHP_POOL_CONF already exists! Skipping..."
    fi

    echo "Restarting PHP-FPM services..."
    sudo systemctl restart php$PHP_VERSION-fpm
}

disable_default_site() {
    sudo a2dissite 000-default.conf
}

# Function to install Node.js
install_node() {
    echo "Select the Node.js version you want to install (e.g., 18, 20):"
    read -p "Enter Node.js version: " NODE_VERSION
    echo "Installing Node.js version $NODE_VERSION..."
    curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | sudo -E bash -
    sudo apt install -y nodejs
    echo "Node.js and npm versions installed:"
    node -v
    npm -v
}

# Function to install MariaDB
install_mariadb() {
    request_parameter "MARIADB_VERSION" "Enter MariaDB version"
    echo "Installing MariaDB version $MARIADB_VERSION..."
    sudo apt install software-properties-common -y
    sudo apt-key adv --fetch-keys 'https://mariadb.org/mariadb_release_signing_key.asc'
    sudo add-apt-repository "deb [arch=amd64,arm64,ppc64el] http://mirror.i3d.net/pub/mariadb/repo/$MARIADB_VERSION/ubuntu $(lsb_release -cs) main" -y
    sudo apt update
    sudo apt install -y mariadb-server mariadb-client
    sudo mysql_secure_installation
    echo "MariaDB installed and secured."
}

# Function to install Composer
install_composer() {
    echo "install the following packages (composer dependencies)"
    sudo apt install gzip tar unrar unzip -y
    echo "Installing Composer..."
    sudo php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    sudo php -r "if (hash_file('sha384', 'dac665fdc30fdd8ec78b38b9800061b4150413ff2e3b6f88543c636f7cd84f6db9189d43a81e5503cda447da73c7e5b6') { echo 'Installer verified'; } else { echo 'Installer corrupt'; unlink('composer-setup.php'); } echo PHP_EOL;"
    sudo php composer-setup.php
    sudo php -r "unlink('composer-setup.php');"
    sudo mv composer.phar /usr/local/bin/composer
    echo "Composer installed successfully."
}

# Function to install Jenkins
install_jenkins() {
    echo "Installing Jenkins..."
    sudo wget -O /usr/share/keyrings/jenkins-keyring.asc https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key
    echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" | sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null
    sudo apt update
    sudo apt install -y jenkins
    echo "Installing Java..."
    sudo apt install -y fontconfig openjdk-17-jre
    java -version
    sudo systemctl enable jenkins
    sudo systemctl start jenkins
    echo "Fetching Jenkins initial admin password..."
    sudo cat /var/lib/jenkins/secrets/initialAdminPassword
    echo -e "\nUse this password to complete Jenkins setup in your browser."
}

# Main script logic
echo "Updating and upgrading the system..."
sudo apt update && sudo apt upgrade -y

echo "Welcome! Please select the steps you'd like to perform."

read -p "Do you want to create a user and set up directories? (yes/no): " DO_USER
if [[ "$DO_USER" == "yes" ]]; then
    create_user
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

echo "Setup complete. Thank you!" 


# this is in .htaccess in the same public_html
# <IfModule mime_module>
#   RewriteEngine On
#   RewriteCond %{HTTP_HOST} !^albasheer\.dev$ [NC]
#   RewriteCond %{HTTP_HOST} !^www\.albasheer\.dev$ [NC]
#   RewriteRule ^ - [F]
#   DirectoryIndex index.php index.html
# </IfModule>




# to use this file 
# chmod +x setup_server.sh
# ./setup_server.sh


# rsync -avz --progress /home/username/ user@new_server:/home/username/ 
# scp database_name.sql user@new_server:/path/to/destination
