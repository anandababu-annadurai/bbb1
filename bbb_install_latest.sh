#!/bin/bash
# Debug and Manual Greenlight Setup Script

echo "=== Debugging Greenlight Installation ==="

# Check current environment
echo "1. Checking rbenv environment..."
export RBENV_ROOT=/usr/local/rbenv
export PATH=$RBENV_ROOT/bin:$PATH

if command -v rbenv >/dev/null 2>&1; then
    eval "$(rbenv init -)"
    echo "rbenv initialized successfully"
    rbenv version
else
    echo "ERROR: rbenv not found in PATH"
    exit 1
fi

# Check Ruby and Bundle
echo "2. Checking Ruby and Bundle..."
ruby -v
which bundle
bundle -v

# Check Greenlight directory
echo "3. Checking Greenlight directory..."
cd /var/www/greenlight
pwd
ls -la

# Check if Gemfile exists
if [ -f "Gemfile" ]; then
    echo "Gemfile found"
    head -10 Gemfile
else
    echo "ERROR: Gemfile not found!"
    exit 1
fi

# Check database config
echo "4. Checking database configuration..."
if [ -f "config/database.yml" ]; then
    echo "database.yml found"
else
    echo "WARNING: database.yml not found"
fi

# Test PostgreSQL connection
echo "5. Testing PostgreSQL connection..."
sudo -u postgres psql -c "\l" | grep greenlight

echo "6. Setting up bundle configuration..."
bundle config set deployment true
bundle config set without 'development test'

echo "7. Installing gems (this may take a while)..."
bundle install --verbose

echo "8. Setting up database..."
RAILS_ENV=production bundle exec rake db:setup

echo "=== Setup completed successfully ==="
