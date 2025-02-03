#!/bin/bash

echo "This script installs a new Email Script instance on Ubuntu 24.04 server."
echo "This script does not ensure system security."
echo ""

# Generate a path for a log file to output into for debugging
LOGPATH=$(realpath "emailscript_install_$(date +%s).log")

# Get the current user running the script
SCRIPT_USER="${SUDO_USER:-$USER}"

# Get the current machine IP address
CURRENT_IP=$(ip addr | grep 'state UP' -A4 | grep 'inet ' | awk '{print $2}' | cut -f1  -d'/')

# Generate a password for the database
DB_PASS="$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 13)"

# The directory to install emailscript into
EMAILSCRIPT_DIR="/var/www/emailscript"

# Get the domain from the arguments (Requested later if not set)
DOMAIN=$1

# Prevent interactive prompts in applications
export DEBIAN_FRONTEND=noninteractive

# Echo out an error message to the command line and exit the program
# Also logs the message to the log file
function error_out() {
  echo "ERROR: $1" | tee -a "$LOGPATH" 1>&2
  exit 1
}

# Echo out an information message to both the command line and log file
function info_msg() {
  echo "$1" | tee -a "$LOGPATH"
}

# Ask for user confirmation before proceeding
function ask_confirmation() {
  local message=$1
  read -p "$message (y/n): " CONFIRM
  if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    error_out "Operation aborted by user."
  fi
}

# Run some checks before installation to help prevent messing up an existing
# web-server setup.
function run_pre_install_checks() {
  # Check we're running as root and exit if not
  if [[ $EUID -gt 0 ]]; then
    error_out "This script must be ran with root/sudo privileges"
  fi

  # Check if Apache is installed and ask for confirmation to proceed
  if [ -d "/etc/apache2/sites-enabled" ]; then
    ask_confirmation "Apache is already installed. Do you want to proceed? Existing configurations may be overwritten."
  fi

  # Check if MySQL is installed and ask for confirmation to proceed
  if [ -d "/var/lib/mysql" ]; then
    ask_confirmation "MySQL is already installed. Do you want to proceed? Existing databases may be affected."
  fi

  # Check if PHP is installed and ask for confirmation to proceed
  if dpkg -l | grep -q 'php8.3'; then
    ask_confirmation "PHP 8.3 is already installed. Do you want to proceed?"
  fi
}

# Fetch domain to use from first provided parameter,
# Otherwise request the user to input their domain
function run_prompt_for_domain_if_required() {
  if [ -z "$DOMAIN" ]; then
    info_msg ""
    info_msg "Enter the domain (or IP if not using a domain) you want to host emailscript on and press [ENTER]."
    info_msg "Examples: my-site.com or docs.my-site.com or ${CURRENT_IP}"
    read -r DOMAIN
  fi

  # Error out if no domain was provided
  if [ -z "$DOMAIN" ]; then
    error_out "A domain must be provided to run this script"
  fi
}

# Install core system packages
function run_package_installs() {
  # Check if packages are already installed
  if ! dpkg -l | grep -q 'apache2\|mariadb-server\|php8.3'; then
    apt update
    apt install -y git unzip apache2 curl mariadb-server php8.3 \
    php8.3-fpm php8.3-curl php8.3-mbstring php8.3-ldap php8.3-xml php8.3-zip php8.3-gd php8.3-mysql php8.3-intl
  else
    info_msg "Required packages are already installed, skipping package installation."
  fi
}

# Set up database
function run_database_setup() {
  # Ensure database service has started
  systemctl start mariadb.service
  sleep 3

  # Check if MySQL is already installed
  if [ -d "/var/lib/mysql" ]; then
    echo "MySQL is already installed."
    echo -n "Enter MySQL root password (leave blank if no password is set): "
    read MYSQL_ROOT_PASSWORD
  else
    MYSQL_ROOT_PASSWORD=""
  fi

  # Check if the database and user already exist
  if ! sudo mysql -u root ${MYSQL_ROOT_PASSWORD:+-p$MYSQL_ROOT_PASSWORD} -e "USE emailscript;" 2>/dev/null; then
    # Create the required user database, user and permissions in the database
    sudo mysql -u root ${MYSQL_ROOT_PASSWORD:+-p$MYSQL_ROOT_PASSWORD} --execute="CREATE DATABASE IF NOT EXISTS emailscript;"
    sudo mysql -u root ${MYSQL_ROOT_PASSWORD:+-p$MYSQL_ROOT_PASSWORD} --execute="CREATE USER IF NOT EXISTS 'emailscript'@'localhost' IDENTIFIED BY '$DB_PASS';"
    sudo mysql -u root ${MYSQL_ROOT_PASSWORD:+-p$MYSQL_ROOT_PASSWORD} --execute="GRANT ALL PRIVILEGES ON emailscript.* TO 'emailscript'@'localhost'; FLUSH PRIVILEGES;"
  else
    info_msg "Database and user already exist, skipping database setup."
  fi
}

# Download emailscript
function run_emailscript_download() {
  if [ ! -d "$EMAILSCRIPT_DIR" ]; then
    cd /var/www || exit
    git clone https://github.com/DilshikaPriyashan/test-email-script.git --branch master --single-branch emailscript
  else
    info_msg "EmailScript directory already exists, skipping download."
  fi
}

# Install composer
function run_install_composer() {
  if ! command -v composer &> /dev/null; then
    EXPECTED_CHECKSUM="$(php -r 'copy("https://composer.github.io/installer.sig", "php://stdout");')"
    php -r "copy('https://getcomposer.org/installer', 'composer-setup.php');"
    ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', 'composer-setup.php');")"

    if [ "$EXPECTED_CHECKSUM" != "$ACTUAL_CHECKSUM" ]; then
        >&2 echo 'ERROR: Invalid composer installer checksum'
        rm composer-setup.php
        exit 1
    fi

    php composer-setup.php --quiet
    rm composer-setup.php

    # Move composer to global installation
    mv composer.phar /usr/local/bin/composer
  else
    info_msg "Composer is already installed, skipping installation."
  fi
}

# Install emailscript composer dependencies
function run_install_emailscript_composer_deps() {
  cd "$EMAILSCRIPT_DIR" || exit
  if [ ! -d "vendor" ]; then
    export COMPOSER_ALLOW_SUPERUSER=1
    php /usr/local/bin/composer install --no-dev --no-plugins
  else
    info_msg "Composer dependencies are already installed, skipping installation."
  fi
}

# Copy and update emailscript environment variables
function run_update_emailscript_env() {
  cd "$EMAILSCRIPT_DIR" || exit
  if [ ! -f ".env" ]; then
    cp .env.example .env
    sed -i.bak "s@APP_URL=.*\$@APP_URL=http://$DOMAIN@" .env
    sed -i.bak "s/DB_CONNECTION=.*$/DB_CONNECTION=mysql/" .env
    sed -i.bak 's/DB_DATABASE=.*$/DB_DATABASE=emailscript/' .env
    sed -i.bak 's/DB_USERNAME=.*$/DB_USERNAME=emailscript/' .env
    sed -i.bak "s/DB_PASSWORD=.*\$/DB_PASSWORD=$DB_PASS/" .env
    # Generate the application key
    php artisan key:generate --no-interaction --force
  else
    info_msg ".env file already exists, skipping environment setup."
  fi
}

# Run the emailscript database migrations and seeders for the first time
function run_emailscript_database_migrations() {
  cd "$EMAILSCRIPT_DIR" || exit
  if ! sudo mysql -u root -e "USE emailscript; SHOW TABLES;" | grep -q migrations; then
    php artisan migrate --no-interaction --force
    php artisan db:seed --no-interaction --force
  else
    info_msg "Database migrations have already been run, skipping migrations."
  fi
}

function create_user_and_password() {
  cd "$EMAILSCRIPT_DIR" || exit
  read -p "Enter user name: " USER_NAME
  read -p "Enter user email: " USER_EMAIL
  read -s -p "Enter user password: " USER_PASSWORD
  echo "" # Move to a new line after hidden input
  
  # Validate the inputs
  if [[ -z "$USER_NAME" || -z "$USER_EMAIL" || -z "$USER_PASSWORD" ]]; then
    echo "Error: All fields are required."
    return 1
  fi

  # Attempt to create the user and check for errors
  if php artisan make:filament-user --name="$USER_NAME" --email="$USER_EMAIL" --password="$USER_PASSWORD"; then
    echo "User created successfully."
  else
    echo "Failed to create user. Please check the logs for details."
    return 1
  fi
}

# Set file and folder permissions
# Sets current user as owner user and www-data as owner group then
# provides group write access only to required directories.
# Hides the `.env` file so it's not visible to other users on the system.
function run_set_application_file_permissions() {
  cd "$EMAILSCRIPT_DIR" || exit
  chown -R "$SCRIPT_USER":www-data ./
  chmod -R 755 ./
  chmod -R 775 bootstrap/cache storage
  chmod 740 .env

  # Tell git to ignore permission changes
  git config core.fileMode false
}

# Setup apache with the needed modules and config
function run_configure_apache() {
  # Enable required apache modules and config
  a2enmod rewrite proxy_fcgi setenvif
  a2enconf php8.3-fpm

  # Set-up the required emailscript apache config
  if [ ! -f "/etc/apache2/sites-available/emailscript.conf" ]; then
    cat >/etc/apache2/sites-available/emailscript.conf <<EOL
<VirtualHost *:80>
  ServerName ${DOMAIN}

  ServerAdmin webmaster@localhost
  DocumentRoot /var/www/emailscript/public/

  <Directory /var/www/emailscript/public/>
      Options -Indexes +FollowSymLinks
      AllowOverride None
      Require all granted
      <IfModule mod_rewrite.c>
          <IfModule mod_negotiation.c>
              Options -MultiViews -Indexes
          </IfModule>

          RewriteEngine On

          # Handle Authorization Header
          RewriteCond %{HTTP:Authorization} .
          RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]

          # Redirect Trailing Slashes If Not A Folder...
          RewriteCond %{REQUEST_FILENAME} !-d
          RewriteCond %{REQUEST_URI} (.+)/$
          RewriteRule ^ %1 [L,R=301]

          # Handle Front Controller...
          RewriteCond %{REQUEST_FILENAME} !-d
          RewriteCond %{REQUEST_FILENAME} !-f
          RewriteRule ^ index.php [L]
      </IfModule>
  </Directory>

  ErrorLog \${APACHE_LOG_DIR}/error.log
  CustomLog \${APACHE_LOG_DIR}/access.log combined

</VirtualHost>
EOL

    # Disable the default apache site and enable emailscript
    a2dissite 000-default.conf
    a2ensite emailscript.conf

    # Restart apache to load new config
    systemctl restart apache2
    # Ensure php-fpm service has started
    systemctl start php8.3-fpm.service
  else
    info_msg "Apache configuration for EmailScript already exists, skipping configuration."
  fi
}

info_msg "This script logs full output to $LOGPATH which may help upon issues."
sleep 1

run_pre_install_checks
run_prompt_for_domain_if_required
info_msg ""
info_msg "Installing using the domain or IP \"$DOMAIN\""
info_msg ""
sleep 1

info_msg "[1/10] Installing required system packages... (This may take several minutes)"
run_package_installs >> "$LOGPATH" 2>&1

info_msg "[2/10] Preparing MySQL database..."
run_database_setup

info_msg "[3/10] Downloading EmailScript to ${EMAILSCRIPT_DIR}..."
run_emailscript_download >> "$LOGPATH" 2>&1

info_msg "[4/10] Installing Composer (PHP dependency manager)..."
run_install_composer >> "$LOGPATH" 2>&1

info_msg "[5/10] Installing PHP dependencies using composer..."
run_install_emailscript_composer_deps >> "$LOGPATH" 2>&1

info_msg "[6/10] Creating and populating EmailScript .env file..."
run_update_emailscript_env >> "$LOGPATH" 2>&1

info_msg "[7/10] Running initial EmailScript database migrations..."
run_emailscript_database_migrations >> "$LOGPATH" 2>&1

info_msg "[8/10] Setting EmailScript file & folder permissions..."
run_set_application_file_permissions >> "$LOGPATH" 2>&1

info_msg "[9/10] Configuring apache server..."
run_configure_apache >> "$LOGPATH" 2>&1

info_msg "[10/10] Create user & password..."
create_user_and_password

info_msg "----------------------------------------------------------------"
info_msg "Setup finished, your EmailScript instance should now be installed!"
info_msg "- Default login email: $USER_EMAIL"
info_msg "- Default login password: $USER_PASSWORD"
info_msg "- Access URL: http://$CURRENT_IP/ or http://$DOMAIN/"
info_msg "- EmailScript install path: $EMAILSCRIPT_DIR"
info_msg "- Install script log: $LOGPATH"
info_msg "---------------------------------------------------------------"