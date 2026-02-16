#!/bin/bash
set -e

# Update system
yum update -y

# Install Docker
yum install -y docker
systemctl enable docker
systemctl start docker

# Add ec2-user to docker group
usermod -aG docker ec2-user

# Install CloudWatch Agent (free tier: 5GB log ingestion + 5GB storage)
yum install -y amazon-cloudwatch-agent

# Create logs directory for Docker container output
mkdir -p /home/ec2-user/notes-app/logs

# Configure CloudWatch Agent for structured logging
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'CWEOF'
{
  "agent": {
    "run_as_user": "root"
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/home/ec2-user/notes-app/logs/app.log",
            "log_group_name": "${log_group_app}",
            "log_stream_name": "{instance_id}/app",
            "retention_in_days": 7
          },
          {
            "file_path": "/var/log/messages",
            "log_group_name": "${log_group_sys}",
            "log_stream_name": "{instance_id}/system",
            "retention_in_days": 7
          }
        ]
      }
    }
  }
}
CWEOF

# Start CloudWatch Agent
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 \
  -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json -s

# Login to ECR (uses instance role credentials via IMDS)
REGION="${aws_region}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION")
aws ecr get-login-password --region "$REGION" | \
  docker login --username AWS --password-stdin "$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com"

# Run placeholder container until first CI/CD deployment pushes a real image
# The deploy workflow will: docker pull -> docker stop -> docker run
docker run -d \
  --name notes-app \
  --restart unless-stopped \
  -p 3000:3000 \
  -e PORT=3000 \
  -e AWS_REGION=${aws_region} \
  -e DYNAMODB_TABLE=${dynamodb_table} \
  -e NODE_ENV=${environment} \
  -v /home/ec2-user/notes-app/logs:/app/logs \
  node:18-alpine \
  sh -c 'node -e "
const http = require(\"http\");
http.createServer((req, res) => {
  if (req.url === \"/health\") {
    res.writeHead(200, {\"Content-Type\": \"application/json\"});
    res.end(JSON.stringify({status: \"healthy\", message: \"Waiting for deployment...\"}));
  } else {
    res.writeHead(404);
    res.end();
  }
}).listen(3000, \"0.0.0.0\", () => console.log(\"Placeholder running on 3000\"));
"'

# Set permissions
chown -R ec2-user:ec2-user /home/ec2-user/notes-app

# Wait for container to start
sleep 5

# Log status
docker ps
echo "Docker setup completed successfully!"
