#!/bin/bash
set -e

# Update system
yum update -y

# Install Node.js 18
curl -fsSL https://rpm.nodesource.com/setup_18.x | bash -
yum install -y nodejs

# Create app directory
mkdir -p /home/ec2-user/notes-app
cd /home/ec2-user/notes-app

# Create package.json
cat > package.json << 'EOF'
{
  "name": "notes-api",
  "version": "1.0.0",
  "main": "src/server.js",
  "dependencies": {
    "express": "^4.18.2",
    "aws-sdk": "^2.1450.0",
    "body-parser": "^1.20.2",
    "uuid": "^9.0.0"
  }
}
EOF

# Create src directory
mkdir -p src

# Create a placeholder server (will be replaced by deployment)
cat > src/server.js << 'EOFSERVER'
const express = require('express');
const app = express();
const port = 3000;

app.get('/health', (req, res) => {
  res.json({ 
    status: 'healthy', 
    timestamp: new Date().toISOString(),
    message: 'Waiting for deployment...'
  });
});

app.listen(port, '0.0.0.0', () => {
  console.log(`Placeholder server running on port $${port}`);
});
EOFSERVER

# Install dependencies
npm install --production

# Create systemd service
cat > /etc/systemd/system/notes-app.service << 'EOF'
[Unit]
Description=Notes API Service
After=network.target

[Service]
Type=simple
User=ec2-user
WorkingDirectory=/home/ec2-user/notes-app
Environment="PORT=3000"
Environment="AWS_REGION=${aws_region}"
Environment="DYNAMODB_TABLE=${dynamodb_table}"
Environment="NODE_ENV=${environment}"
ExecStart=/usr/bin/node src/server.js
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Set permissions
chown -R ec2-user:ec2-user /home/ec2-user/notes-app

# Start service
systemctl daemon-reload
systemctl enable notes-app
systemctl start notes-app

# Wait for service to start
sleep 5

# Log status
systemctl status notes-app

echo "Installation completed successfully!"
