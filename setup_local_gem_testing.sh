#!/bin/bash

# Script to set up local gem testing in Docker
# Run this from your Rails app directory

echo "Setting up local ActiveRabbit gem testing..."

# Check if we're in a Rails app directory
if [ ! -f "Gemfile" ]; then
    echo "Error: No Gemfile found. Please run this from your Rails app directory."
    exit 1
fi

# Backup original Gemfile
cp Gemfile Gemfile.backup

# Add local gem path to Gemfile
echo "" >> Gemfile
echo "# Local ActiveRabbit gem for testing" >> Gemfile
echo "gem 'activerabbit-ai', path: '/app/gems/active_rabbit-client'" >> Gemfile

echo "✅ Added local gem path to Gemfile"

# Create docker-compose override for local development
cat > docker-compose.override.yml << EOF
version: '3.8'
services:
  web:
    volumes:
      # Mount local ActiveRabbit gem
      - /Users/alex/GPT/activeagent/active_rabbit-client:/app/gems/active_rabbit-client:ro
    environment:
      - ACTIVERABBIT_API_KEY=9b3344ba8775e8ab11fd47e04534ae81e938180a23de603e60b5ec4346652f06
      - ACTIVERABBIT_PROJECT_ID=1
      - ACTIVERABBIT_API_URL=http://host.docker.internal:3000
EOF

echo "✅ Created docker-compose.override.yml"

echo ""
echo "🚀 Setup complete! Now run:"
echo "   docker-compose down"
echo "   docker-compose build"
echo "   docker-compose up"
echo ""
echo "To restore original setup:"
echo "   mv Gemfile.backup Gemfile"
echo "   rm docker-compose.override.yml"
