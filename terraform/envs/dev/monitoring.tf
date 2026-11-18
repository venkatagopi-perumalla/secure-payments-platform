resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_cloudwatch_metric_alarm" "alb_5xx_rate" {
  alarm_name          = "${local.name}-5xx-rate"
  alarm_description   = "More than 2 percent of requests failed with a server error"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 2
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]

  metric_query {
    id          = "rate"
    expression  = "100 * errors / MAX([errors, requests])"
    label       = "5xx percent"
    return_data = true
  }
  metric_query {
    id = "errors"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      period      = 60
      stat        = "Sum"
      dimensions  = { LoadBalancer = module.service.alb_arn_suffix }
    }
  }
  metric_query {
    id = "requests"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      period      = 60
      stat        = "Sum"
      dimensions  = { LoadBalancer = module.service.alb_arn_suffix }
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "alb_p95_latency" {
  alarm_name          = "${local.name}-p95-latency"
  alarm_description   = "95th percentile response time above 1 second"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p95"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  threshold           = 1
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions          = { LoadBalancer = module.service.alb_arn_suffix }
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name          = "${local.name}-unhealthy-targets"
  alarm_description   = "At least one API task is failing health checks"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions = {
    LoadBalancer = module.service.alb_arn_suffix
    TargetGroup  = module.service.target_group_arn_suffix
  }
  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "ecs_cpu" {
  alarm_name          = "${local.name}-ecs-cpu-high"
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  dimensions = {
    ClusterName = module.service.cluster_name
    ServiceName = module.service.service_name
  }
  alarm_actions = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${local.name}-rds-cpu-high"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  dimensions          = { DBInstanceIdentifier = "payments-postgres" }
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "rds_storage" {
  alarm_name          = "${local.name}-rds-storage-low"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 2147483648 # 2 GiB in bytes
  comparison_operator = "LessThanThreshold"
  dimensions          = { DBInstanceIdentifier = "payments-postgres" }
  alarm_actions       = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${local.name}-overview"
  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 12, height = 6
        properties = {
          title  = "Requests and server errors"
          region = var.region
          stat   = "Sum"
          period = 60
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", module.service.alb_arn_suffix],
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", module.service.alb_arn_suffix],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 0, width = 12, height = 6
        properties = {
          title   = "p95 response time (seconds)"
          region  = var.region
          stat    = "p95"
          period  = 60
          metrics = [["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", module.service.alb_arn_suffix]]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 12, height = 6
        properties = {
          title  = "ECS CPU and memory (percent)"
          region = var.region
          stat   = "Average"
          period = 60
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", module.service.cluster_name, "ServiceName", module.service.service_name],
            ["AWS/ECS", "MemoryUtilization", "ClusterName", module.service.cluster_name, "ServiceName", module.service.service_name],
          ]
        }
      },
      {
        type = "metric", x = 12, y = 6, width = 12, height = 6
        properties = {
          title  = "Database CPU and connections"
          region = var.region
          stat   = "Average"
          period = 300
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", "payments-postgres"],
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", "payments-postgres"],
          ]
        }
      },
    ]
  })
}
