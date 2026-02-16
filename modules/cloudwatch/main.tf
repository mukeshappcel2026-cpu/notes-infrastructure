variable "app_name" {
  description = "Application name"
  type        = string
}

variable "environment" {
  description = "Environment (dev/staging/prod)"
  type        = string
}

variable "ec2_instance_id" {
  description = "EC2 instance ID to monitor"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "sns_email" {
  description = "Email address for alarm notifications (optional, set to empty to skip)"
  type        = string
  default     = ""
}

# ------------------------------------------------------------------
# CloudWatch Free Tier:
#   - 10 custom metrics
#   - 10 alarms
#   - 1M API requests
#   - 5GB log data ingestion
#   - 5GB log data storage
# We use only built-in EC2 metrics (no extra cost) + a few alarms
# ------------------------------------------------------------------

# SNS Topic for alarm notifications (free tier: 1M publishes)
resource "aws_sns_topic" "alerts" {
  name = "${var.app_name}-${var.environment}-alerts"

  tags = {
    Name        = "${var.app_name}-${var.environment}-alerts"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# SNS Email subscription (only if email is provided)
resource "aws_sns_topic_subscription" "email" {
  count     = var.sns_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.sns_email
}

# ------------------------------------------------------------------
# CloudWatch Log Group for application logs
# Retention: 7 days to stay within 5GB free tier storage
# ------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "app" {
  name              = "/${var.app_name}/${var.environment}/application"
  retention_in_days = 7

  tags = {
    Name        = "${var.app_name}-${var.environment}-AppLogs"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

resource "aws_cloudwatch_log_group" "system" {
  name              = "/${var.app_name}/${var.environment}/system"
  retention_in_days = 7

  tags = {
    Name        = "${var.app_name}-${var.environment}-SysLogs"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# ------------------------------------------------------------------
# Alarm 1: EC2 CPU Utilization > 80% for 5 minutes
# Uses built-in AWS/EC2 metrics (no extra cost)
# ------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${var.app_name}-${var.environment}-CPU-High"
  alarm_description   = "EC2 CPU utilization exceeded 80% for 5 minutes"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "notBreaching"

  dimensions = {
    InstanceId = var.ec2_instance_id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name        = "${var.app_name}-${var.environment}-CPU-High"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# ------------------------------------------------------------------
# Alarm 2: EC2 Status Check Failed (instance or system)
# Detects hardware/software failures - built-in metric, no cost
# ------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "status_check_failed" {
  alarm_name          = "${var.app_name}-${var.environment}-StatusCheck-Failed"
  alarm_description   = "EC2 instance or system status check failed"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "breaching"

  dimensions = {
    InstanceId = var.ec2_instance_id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name        = "${var.app_name}-${var.environment}-StatusCheck-Failed"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# ------------------------------------------------------------------
# Alarm 3: DynamoDB Read Throttling
# Uses built-in AWS/DynamoDB metrics (no extra cost)
# ------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "dynamodb_read_throttle" {
  alarm_name          = "${var.app_name}-${var.environment}-DynamoDB-ReadThrottle"
  alarm_description   = "DynamoDB read requests are being throttled"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ReadThrottleEvents"
  namespace           = "AWS/DynamoDB"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    TableName = "Notes"
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = {
    Name        = "${var.app_name}-${var.environment}-DynamoDB-ReadThrottle"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# ------------------------------------------------------------------
# Alarm 4: DynamoDB Write Throttling
# ------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "dynamodb_write_throttle" {
  alarm_name          = "${var.app_name}-${var.environment}-DynamoDB-WriteThrottle"
  alarm_description   = "DynamoDB write requests are being throttled"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "WriteThrottleEvents"
  namespace           = "AWS/DynamoDB"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  treat_missing_data  = "notBreaching"

  dimensions = {
    TableName = "Notes"
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = {
    Name        = "${var.app_name}-${var.environment}-DynamoDB-WriteThrottle"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# ------------------------------------------------------------------
# Alarm 5: API Gateway 5xx Error Rate
# Catches backend failures surfaced through API Gateway
# ------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "api_5xx_errors" {
  alarm_name          = "${var.app_name}-${var.environment}-API-5xxErrors"
  alarm_description   = "API Gateway 5xx error rate exceeded threshold"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "5XXError"
  namespace           = "AWS/ApiGateway"
  period              = 300
  statistic           = "Sum"
  threshold           = 10
  treat_missing_data  = "notBreaching"

  dimensions = {
    ApiName = "${var.app_name}-${var.environment}-API"
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = {
    Name        = "${var.app_name}-${var.environment}-API-5xxErrors"
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# ------------------------------------------------------------------
# Outputs
# ------------------------------------------------------------------

output "sns_topic_arn" {
  description = "SNS topic ARN for alerts"
  value       = aws_sns_topic.alerts.arn
}

output "app_log_group_name" {
  description = "CloudWatch log group name for application logs"
  value       = aws_cloudwatch_log_group.app.name
}

output "system_log_group_name" {
  description = "CloudWatch log group name for system logs"
  value       = aws_cloudwatch_log_group.system.name
}
