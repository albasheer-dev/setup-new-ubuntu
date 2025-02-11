#!/bin/bash

echo "Starting SSL renewal process for all domains..."

# Run Certbot dry-run to check if everything is working
certbot renew --dry-run
if [ $? -ne 0 ]; then
    echo "Certbot dry-run failed. Please check manually."
    exit 1
fi

# Get a list of all active domains
DOMAINS=$(sudo certbot certificates | grep "Certificate Name" | awk '{print $3}')

# Loop through each domain and set a cron job for renewal
for DOMAIN in $DOMAINS; do
    echo "Processing domain: $DOMAIN"

    # Get the certificate expiration date
    CERT_PATH="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    if [ -f "$CERT_PATH" ]; then
        EXPIRY_DATE=$(sudo openssl x509 -enddate -noout -in "$CERT_PATH" | cut -d= -f2)
        EXPIRY_TIMESTAMP=$(date -d "$EXPIRY_DATE" +%s)

        # Calculate 5 days before expiry
        RENEWAL_TIMESTAMP=$((EXPIRY_TIMESTAMP - 432000))  # 5 days = 432000 seconds
        RENEWAL_DATE=$(date -d "@$RENEWAL_TIMESTAMP" "+%d")

        # Add cron job for this domain
        CRON_JOB="0 0 $RENEWAL_DATE * * certbot renew --quiet --cert-name $DOMAIN && systemctl restart apache2"
        (crontab -l 2>/dev/null | grep -v "certbot renew --cert-name $DOMAIN"; echo "$CRON_JOB") | crontab -


        echo "Cron job set for $DOMAIN on day $RENEWAL_DATE of the month."
    else
        echo "Certificate not found for $DOMAIN. Skipping..."
    fi
done

echo "SSL renewal setup complete."
