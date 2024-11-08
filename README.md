# Overview
This setup_server.sh script automates the process of setting up a Linux server with commonly used services and configurations. It provides a user-friendly interface to install and configure the following:

1. User Management: Create a new user with a public web directory.
2. Apache: Install and configure Apache with user-specific virtual hosts.
3. PHP: Install a specific version of PHP with FPM configuration for each user.
4. Node.js: Install the desired version of Node.js and npm.
5. MariaDB: Install and secure MariaDB.
6. Composer: Install Composer for managing PHP dependencies.
7. Jenkins: Install and set up Jenkins for CI/CD.
8. System Update: Update and upgrade the system.


# Features
* Interactive Input: Prompts the user to input required information (e.g., usernames, PHP versions, domain names).
* Custom Configuration: Automatically generates and applies configuration files for Apache, PHP, and other services.
* Selective Execution: Allows users to run only the desired parts of the setup.
* Reusable: Skips previously completed steps if configurations already exist.
 

# Prerequisites
* A Linux server with sudo privileges.
* An internet connection for downloading necessary packages and repositories.

# Usage Instructions
1. Prepare the Script:

    * Download the script to your server.
    * Make the script executable:
```bash
chmod +x setup_server.sh
```

2. Run the Script:

```bash
./setup_server.sh
```
Follow the prompts to select and configure the desired services.

3. Transferring Data (Optional):

    * Use rsync to transfer user data:
```bash
rsync -avz --progress /home/username/ user@new_server:/home/username/
```
    * Use scp to transfer database files:
```bash
scp database_name.sql user@new_server:/path/to/destination
```
# Steps Performed by the Script

1. User Creation:

    * Creates a new user and sets up the public_html directory.
    * Grants sudo privileges to the user.
2. Apache Installation:

    * Installs Apache and enables necessary modules.
    * Configures user-specific virtual hosts.
3. PHP Installation:

    * Installs the specified PHP version and its extensions.
    * Configures a PHP-FPM pool for the user.
4. Node.js Installation:

    * Installs the desired version of Node.js and npm.
5. MariaDB Installation:

    * Installs and secures MariaDB using the specified version.
6. Composer Installation:

    * Installs Composer globally for managing PHP dependencies.
7. Jenkins Installation:

    * Installs Jenkins and sets up an admin account.
# Example Inputs
During the script execution, you will be prompted for input such as:

* Username: `john_doe`
* Domain Name: `example.com`
* PHP Version: `8.3`
* MariaDB Version: `10.6`
# Troubleshooting
* If a configuration file already exists, the script skips that step to avoid overwriting.
* Make sure to install required dependencies (e.g., curl, unzip, etc.) before running the script.
* Check log files (e.g., error.log, access.log) in the user's home directory for debugging.
# Notes
* Modify the script to suit your specific needs or server environment.
* Always test the script in a staging environment before deploying it to production.
Enjoy automating your server setup! 🎉




