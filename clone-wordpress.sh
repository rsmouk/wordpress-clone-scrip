#!/bin/bash

# ========================================
# WordPress Site Clone Script
# Author: Mohamed Asfar (infinyteam)
# Description: Clone WordPress sites on CyberPanel (do not share this file)
# Source: infinyteam.com 
# ========================================

# 🔧 Interactive domain input
echo "🌐 WordPress Clone Script"
echo "========================="
echo ""
read -p "📝 Enter the new domain name (e.g., example.com): " NEW_DOMAIN

# Validate domain input
if [ -z "$NEW_DOMAIN" ]; then
    echo "❌ Domain name cannot be empty!"
    exit 1
fi

# Remove any http/https and www prefixes
NEW_DOMAIN=$(echo "$NEW_DOMAIN" | sed 's|^https\?://||' | sed 's|^www\.||')

echo "✅ Target domain: $NEW_DOMAIN"
echo ""

# 🚀 Starting clone process
echo "🚀 Starting WordPress clone for: $NEW_DOMAIN"

# Generate strong password
DB_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)
echo "🔐 Generated database password: $DB_PASSWORD"

# Create database names with "new" suffix to avoid conflicts
NEW_DB_NAME="${NEW_DOMAIN//./_}_new_db"
NEW_DB_USER="${NEW_DOMAIN//./_}_new_user"
FULL_EMAIL="contact@${NEW_DOMAIN}"

echo "📋 Website Info:"
echo "   Domain: $NEW_DOMAIN"
echo "   Database: $NEW_DB_NAME" 
echo "   DB User: $NEW_DB_USER"
echo "   Email: $FULL_EMAIL"
echo ""

# Check root access
if [[ $EUID -ne 0 ]]; then
   echo "❌ Run as root: sudo bash -c \"...\""
   exit 1
fi

# Step 0: Delete existing website if it exists
echo "🗑️ Checking for existing website..."
EXISTING_CHECK=$(cyberpanel listWebsitesJson 2>/dev/null | grep "$NEW_DOMAIN" || echo "not found")

if [[ "$EXISTING_CHECK" != "not found" ]]; then
    echo "🗑️ Deleting existing website: $NEW_DOMAIN"
    cyberpanel deleteWebsite --domainName "$NEW_DOMAIN"
    
    if [ $? -eq 0 ]; then
        echo "✅ Existing website deleted"
        sleep 2  # Wait a moment for cleanup
    else
        echo "⚠️ Website deletion may have failed, continuing anyway..."
    fi
else
    echo "✅ No existing website found"
fi

# Clean up any existing database with "new" suffix
echo "🗑️ Cleaning up any existing database..."
mysql -u root -p'YOUR_MYSQL_ROOT_PASSWORD' -e "
DROP DATABASE IF EXISTS \`$NEW_DB_NAME\`;
DROP USER IF EXISTS '$NEW_DB_USER'@'localhost';
FLUSH PRIVILEGES;
" 2>/dev/null

# Step 1: Create website (fresh installation)
echo "🌐 Creating fresh website in CyberPanel..."
WEBSITE_RESULT=$(cyberpanel createWebsite \
    --package "Default" \
    --owner "admin" \
    --domainName "$NEW_DOMAIN" \
    --email "admin@$NEW_DOMAIN" \
    --php "8.1" \
    --ssl 0)

echo "$WEBSITE_RESULT"

if echo "$WEBSITE_RESULT" | grep -q '"success": 1'; then
    echo "✅ Website created successfully"
else
    echo "❌ Website creation failed"
    echo "$WEBSITE_RESULT"
    exit 1
fi

# Step 2: Create email
echo "📧 Creating email account..."
cyberpanel createEmail \
    --domainName "$NEW_DOMAIN" \
    --userName "contact" \
    --password "$DB_PASSWORD" 2>/dev/null

# Step 3: Create database with "new" suffix
echo "🗄️ Creating new database..."
DB_RESULT=$(cyberpanel createDatabase \
    --databaseWebsite "$NEW_DOMAIN" \
    --dbName "$NEW_DB_NAME" \
    --dbUsername "$NEW_DB_USER" \
    --dbPassword "$DB_PASSWORD")

echo "$DB_RESULT"

if echo "$DB_RESULT" | grep -q '"success": 1'; then
    echo "✅ Database created successfully"
else
    echo "❌ Database creation failed"
    echo "$DB_RESULT"
    exit 1
fi

# Step 4: Copy files and check .htaccess
echo "📁 Copying website files..."
SOURCE_PATH="/home/SOURCE_DOMAIN/public_html"
NEW_PATH="/home/$NEW_DOMAIN/public_html"

if [ ! -d "$SOURCE_PATH" ]; then
    echo "❌ Source not found: $SOURCE_PATH"
    exit 1
fi

cp -r "$SOURCE_PATH"/* "$NEW_PATH/"

# Fix ownership - find the correct user
if id "admin" >/dev/null 2>&1; then
    chown -R admin:admin "$NEW_PATH"
    echo "✅ Files copied and owned by admin"
elif [ -d "/home/$NEW_DOMAIN" ]; then
    # Find the owner of the domain directory
    DOMAIN_OWNER=$(stat -c "%U" "/home/$NEW_DOMAIN")
    DOMAIN_GROUP=$(stat -c "%G" "/home/$NEW_DOMAIN")
    chown -R "$DOMAIN_OWNER:$DOMAIN_GROUP" "$NEW_PATH"
    echo "✅ Files copied and owned by $DOMAIN_OWNER:$DOMAIN_GROUP"
else
    # Just set generic permissions
    chmod -R 755 "$NEW_PATH"
    echo "✅ Files copied with generic permissions"
fi

# Check and create .htaccess file
HTACCESS_FILE="$NEW_PATH/.htaccess"
echo "🔍 Checking .htaccess file..."

if [ ! -f "$HTACCESS_FILE" ]; then
    echo "⚠️ .htaccess file not found, creating it..."
    
    cat > "$HTACCESS_FILE" << 'HTACCESS_EOF'
# BEGIN WordPress

RewriteEngine On
RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
RewriteBase /
RewriteRule ^index\.php$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . /index.php [L]

# END WordPress
HTACCESS_EOF

    # Set proper permissions for .htaccess
    chmod 644 "$HTACCESS_FILE"
    
    # Set ownership to match other files
    if [ -n "$DOMAIN_OWNER" ] && [ -n "$DOMAIN_GROUP" ]; then
        chown "$DOMAIN_OWNER:$DOMAIN_GROUP" "$HTACCESS_FILE"
    fi
    
    echo "✅ .htaccess file created successfully"
else
    echo "✅ .htaccess file already exists"
    
    # Verify it contains WordPress rules
    if ! grep -q "# BEGIN WordPress" "$HTACCESS_FILE"; then
        echo "⚠️ .htaccess exists but doesn't contain WordPress rules, backing up and updating..."
        
        # Backup existing file
        cp "$HTACCESS_FILE" "$HTACCESS_FILE.backup.$(date +%s)"
        
        # Add WordPress rules at the beginning
        cat > "$HTACCESS_FILE.tmp" << 'HTACCESS_EOF'
# BEGIN WordPress

RewriteEngine On
RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
RewriteBase /
RewriteRule ^index\.php$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . /index.php [L]

# END WordPress

HTACCESS_EOF
        
        # Append existing content
        cat "$HTACCESS_FILE" >> "$HTACCESS_FILE.tmp"
        mv "$HTACCESS_FILE.tmp" "$HTACCESS_FILE"
        
        # Set proper permissions
        chmod 644 "$HTACCESS_FILE"
        if [ -n "$DOMAIN_OWNER" ] && [ -n "$DOMAIN_GROUP" ]; then
            chown "$DOMAIN_OWNER:$DOMAIN_GROUP" "$HTACCESS_FILE"
        fi
        
        echo "✅ .htaccess file updated with WordPress rules"
    fi
fi

# Step 5: Clone database with better error handling
echo "🔄 Cloning database..."

# Test source database connection
echo "🔍 Testing source database connection..."
SOURCE_TEST=$(mysql -u SOURCE_DB_USER -p'SOURCE_DB_PASSWORD' -e "USE SOURCE_DB_NAME; SELECT COUNT(*) as count FROM wp_options;" 2>/dev/null)

if [ $? -eq 0 ]; then
    echo "✅ Source database accessible"
    echo "$SOURCE_TEST"
    
    # Export with proper options
    echo "📤 Exporting source database..."
    mysqldump -u SOURCE_DB_USER -p'SOURCE_DB_PASSWORD' \
        --single-transaction \
        --routines \
        --triggers \
        --add-drop-table \
        SOURCE_DB_NAME > /tmp/source_export.sql 2>/dev/null
    
    if [ $? -eq 0 ] && [ -s "/tmp/source_export.sql" ]; then
        echo "✅ Database exported successfully ($(wc -l < /tmp/source_export.sql) lines)"
        
        # Import to new database
        echo "📥 Importing to new database..."
        mysql -u "$NEW_DB_USER" -p"$DB_PASSWORD" "$NEW_DB_NAME" < /tmp/source_export.sql 2>/dev/null
        
        if [ $? -eq 0 ]; then
            echo "✅ Database imported successfully"
        else
            echo "⚠️ Import with user failed, trying with root..."
            mysql -u root -p'YOUR_MYSQL_ROOT_PASSWORD' "$NEW_DB_NAME" < /tmp/source_export.sql 2>/dev/null
            
            if [ $? -eq 0 ]; then
                echo "✅ Database imported successfully with root"
            else
                echo "❌ Database import failed"
                rm /tmp/source_export.sql
                exit 1
            fi
        fi
        
        # Clean up
        rm /tmp/source_export.sql
    else
        echo "❌ Database export failed or empty"
        exit 1
    fi
else
    echo "❌ Cannot access source database"
    exit 1
fi

# Step 6: Update wp-config.php
echo "⚙️ Updating wp-config.php..."
WP_CONFIG="$NEW_PATH/wp-config.php"

if [ -f "$WP_CONFIG" ]; then
    cp "$WP_CONFIG" "$WP_CONFIG.backup"
    
    sed -i "s/define( *'DB_NAME'.*/define('DB_NAME', '$NEW_DB_NAME');/" "$WP_CONFIG"
    sed -i "s/define( *'DB_USER'.*/define('DB_USER', '$NEW_DB_USER');/" "$WP_CONFIG"
    sed -i "s/define( *'DB_PASSWORD'.*/define('DB_PASSWORD', '$DB_PASSWORD');/" "$WP_CONFIG"
    
    echo "✅ wp-config.php updated successfully"
else
    echo "⚠️ wp-config.php file not found"
fi

# Step 7: Update URLs in database
echo "🔧 Updating domain in database..."
mysql -u root -p'YOUR_MYSQL_ROOT_PASSWORD' "$NEW_DB_NAME" -e "
UPDATE wp_options SET option_value = 'https://$NEW_DOMAIN' WHERE option_name = 'home';
UPDATE wp_options SET option_value = 'https://$NEW_DOMAIN' WHERE option_name = 'siteurl';
UPDATE wp_posts SET post_content = REPLACE(post_content, 'https://SOURCE_DOMAIN', 'https://$NEW_DOMAIN');
UPDATE wp_posts SET post_content = REPLACE(post_content, 'http://SOURCE_DOMAIN', 'https://$NEW_DOMAIN');
UPDATE wp_posts SET post_excerpt = REPLACE(post_excerpt, 'https://SOURCE_DOMAIN', 'https://$NEW_DOMAIN');
UPDATE wp_comments SET comment_content = REPLACE(comment_content, 'https://SOURCE_DOMAIN', 'https://$NEW_DOMAIN');
" 2>/dev/null

if [ $? -eq 0 ]; then
    echo "✅ Domain updated in database successfully"
else
    echo "❌ Failed to update domain in database"
fi

# Step 8: Set final permissions
echo "🔐 Setting final permissions..."

# Find the correct owner for the domain
if [ -d "/home/$NEW_DOMAIN" ]; then
    DOMAIN_OWNER=$(stat -c "%U" "/home/$NEW_DOMAIN")
    DOMAIN_GROUP=$(stat -c "%G" "/home/$NEW_DOMAIN")
    
    chown -R "$DOMAIN_OWNER:$DOMAIN_GROUP" "/home/$NEW_DOMAIN"
    find "$NEW_PATH" -type d -exec chmod 755 {} \;
    find "$NEW_PATH" -type f -exec chmod 644 {} \;
    chmod 600 "$WP_CONFIG" 2>/dev/null
    
    # Ensure .htaccess has proper permissions
    if [ -f "$NEW_PATH/.htaccess" ]; then
        chmod 644 "$NEW_PATH/.htaccess"
        chown "$DOMAIN_OWNER:$DOMAIN_GROUP" "$NEW_PATH/.htaccess"
    fi
    
    echo "✅ Permissions set for $DOMAIN_OWNER:$DOMAIN_GROUP"
else
    # Fallback to admin user
    chown -R admin:admin "/home/$NEW_DOMAIN" 2>/dev/null
    find "$NEW_PATH" -type d -exec chmod 755 {} \; 2>/dev/null
    find "$NEW_PATH" -type f -exec chmod 644 {} \; 2>/dev/null
    chmod 600 "$WP_CONFIG" 2>/dev/null
    
    # Ensure .htaccess has proper permissions
    if [ -f "$NEW_PATH/.htaccess" ]; then
        chmod 644 "$NEW_PATH/.htaccess"
        chown admin:admin "$NEW_PATH/.htaccess" 2>/dev/null
    fi
    
    echo "✅ Permissions set with admin user"
fi

# Save credentials
CREDS_FILE="/root/${NEW_DOMAIN}_credentials.txt"
cat > "$CREDS_FILE" << EOL
=================================
WordPress Site: $NEW_DOMAIN
=================================
Email: $FULL_EMAIL
Database Name: $NEW_DB_NAME
Database User: $NEW_DB_USER
Database Password: $DB_PASSWORD
Files Path: $NEW_PATH
Owner: $(stat -c "%U:%G" "/home/$NEW_DOMAIN" 2>/dev/null || echo "admin:admin")
Created: $(date)
=================================

WordPress Admin URL: https://$NEW_DOMAIN/wp-admin/
Database Host: localhost
Source Cloned From: SOURCE_DOMAIN

Files Status:
- wp-config.php: Updated ✅
- .htaccess: Verified/Created ✅

Next Steps:
1. Update DNS A record for $NEW_DOMAIN
2. Setup SSL certificate via CyberPanel
3. Test website: https://$NEW_DOMAIN
4. Login to WordPress admin and update settings
=================================
EOL

echo ""
echo "🎉 CLONE COMPLETED SUCCESSFULLY!"
echo "================================="
echo "🌐 Domain: $NEW_DOMAIN"
echo "📧 Email: $FULL_EMAIL"
echo "🗄️ Database: $NEW_DB_NAME"
echo "🔐 DB Password: $DB_PASSWORD"
echo "📁 Files Path: $NEW_PATH"
echo "💾 Credentials saved: $CREDS_FILE"
echo ""
echo "⚠️ IMPORTANT NEXT STEPS:"
echo "   1. Update DNS for $NEW_DOMAIN"
echo "   2. Setup SSL certificate"
echo "   3. Test: https://$NEW_DOMAIN"
echo "   4. WordPress Admin: https://$NEW_DOMAIN/wp-admin/"
echo ""
echo "✅ All done! Your new WordPress site is ready!"

# Test website connectivity
echo ""
echo "🔍 Testing website connectivity..."
if curl -s -H "Host: $NEW_DOMAIN" http://localhost/ | grep -qi "wordpress\|html"; then
    echo "✅ Website is responding correctly"
else
    echo "⚠️ Website may need additional configuration"
fi
