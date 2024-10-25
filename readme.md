This project provides a Docker-based infrastructure to deploy web application with separate production and pre-production environments on the same server. 
It leverages Docker Compose to orchestrate multiple services, including Nginx, PHP-Apache, MariaDB, and Certbot for SSL certificates. 
The architecture ensures that both environments are isolated yet efficiently utilize the same resources.

# isolated yet efficiently utilize the same resources.

## Nginx: 
Acts as a reverse proxy and load balancer, handling HTTP/HTTPS requests, SSL termination, and domain-based routing.

## PHP-Apache: 
Runs the PHP web application for both production and pre-production environments.

## MariaDB: Provides separate databases for production and pre-production.

##Certbot: Manages SSL certificates using Let's Encrypt and automates renewal.

##Docker Networks: 
Separate Docker networks (prod_net and preprod_net) to isolate environments.

# Directory Structure


    .
    ├── app
    │   └── ...            # Production application code
    ├── app-preprod
    │   └── ...            # Pre-production application code
    ├── certbot
    │   ├── conf
    │   └── www
    ├── nginx
    │   ├── nginx.conf
    │   └── .htpasswd
    ├── docker-compose.yml
    ├── Dockerfile
    └── README.md


# Configure Environment Variables

    MARIADB_ROOT_PASSWORD_PROD= #yours
    MARIADB_ROOT_PASSWORD_PREPROD= #yours
    CLOUDFLARE_API_TOKEN= #yours
    FTP_SERVER= #yours
    FTP_USER= #yours
    FTP_PASS= #yours

# Configure Cloudflare DNS Validation 

    # ./certbot/cloudflare.ini
    # chmod 600 ./certbot/cloudflare.ini
    # https://developers.cloudflare.com/fundamentals/api/get-started/create-token/
    dns_cloudflare_api_token = "YOUR_CLOUDFLARE_API_TOKEN"

# Update code 
run 
    grep . -Ri "XXXXXX" 
and replace XXXXXX with your Domain

# Build and Run the Containers

    docker compose up -d

# Backup and Upload the Production Application

    ./bin/backup_and_upload.sh
    0 2 1 * * /home/XXXXXX/projects/XXXXXX.com/bin/backup_and_upload.sh >> /home/XXXXXX/backup.log 2>&1


# Verify the Setup

    # http://app.XXXXXX.com
    # http://app-preprod.XXXXXX.com

    docker-compose ps
    docker-compose logs nginx
    docker-compose logs php-apache
    docker-compose logs php-apache-preprod

# Troubleshooting

    docker-compose exec nginx nginx -t
    docker-compose exec php-apache php -v
    docker-compose exec php-apache-preprod php -v


