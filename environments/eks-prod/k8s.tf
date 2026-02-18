###############################################################################
# Kubernetes Resources — Namespace, ConfigMap, Secrets, Deployments,
#                        Services, Ingress, HPA, Redis StatefulSet
###############################################################################

provider "kubernetes" {
  host                   = aws_eks_cluster.main.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.main.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.aws_region]
  }
}

# ---------------------------------------------------------------------------
# Namespace
# ---------------------------------------------------------------------------

resource "kubernetes_namespace" "app" {
  metadata {
    name = var.environment
    labels = {
      environment                   = var.environment
      team                          = "platform"
      "app.kubernetes.io/part-of"   = "notes-app"
    }
  }

  depends_on = [aws_eks_node_group.main]
}

# ---------------------------------------------------------------------------
# Service Accounts (IRSA-annotated)
# ---------------------------------------------------------------------------

resource "kubernetes_service_account" "api" {
  metadata {
    name      = "notes-api-sa"
    namespace = kubernetes_namespace.app.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.notes_api.arn
    }
    labels = {
      "app.kubernetes.io/name"    = "notes-api"
      "app.kubernetes.io/part-of" = "notes-app"
    }
  }
}

resource "kubernetes_service_account" "worker" {
  metadata {
    name      = "notes-worker-sa"
    namespace = kubernetes_namespace.app.metadata[0].name
    annotations = {
      "eks.amazonaws.com/role-arn" = aws_iam_role.notes_worker.arn
    }
    labels = {
      "app.kubernetes.io/name"    = "notes-worker"
      "app.kubernetes.io/part-of" = "notes-app"
    }
  }
}

# ---------------------------------------------------------------------------
# ConfigMaps
# ---------------------------------------------------------------------------

resource "kubernetes_config_map" "config" {
  metadata {
    name      = "notes-config"
    namespace = kubernetes_namespace.app.metadata[0].name
    labels    = { "app.kubernetes.io/part-of" = "notes-app" }
  }

  data = {
    "redis-host"     = "redis.${var.environment}.svc.cluster.local"
    "redis-port"     = "6379"
    "log-level"      = var.environment == "prod" ? "warn" : "debug"
    "cors-origins"   = var.environment == "prod" ? "https://${var.domain_name}" : "http://localhost:3000"
    "rate-limit-rpm" = var.environment == "prod" ? "60" : "200"
  }
}

resource "kubernetes_config_map" "feature_flags" {
  metadata {
    name      = "notes-feature-flags"
    namespace = kubernetes_namespace.app.metadata[0].name
    labels    = { "app.kubernetes.io/part-of" = "notes-app" }
  }

  data = {
    ENABLE_SEARCH      = "true"
    ENABLE_ATTACHMENTS = "true"
    ENABLE_SHARING     = "false"
    MAX_NOTE_SIZE      = var.environment == "prod" ? "50000" : "10000"
  }
}

# ---------------------------------------------------------------------------
# Secrets
# ---------------------------------------------------------------------------

resource "kubernetes_secret" "app" {
  metadata {
    name      = "notes-secrets"
    namespace = kubernetes_namespace.app.metadata[0].name
    labels    = { "app.kubernetes.io/part-of" = "notes-app" }
  }

  data = {
    "google-client-id" = var.google_client_id
    "jwt-secret"       = var.jwt_secret
    "db-password"      = "placeholder-replace-in-ci"
  }

  type = "Opaque"
}

# ---------------------------------------------------------------------------
# Deployment: notes-api
# ---------------------------------------------------------------------------

resource "kubernetes_deployment" "api" {
  wait_for_rollout = false

  metadata {
    name      = "notes-api"
    namespace = kubernetes_namespace.app.metadata[0].name
    labels = {
      app                         = "notes-api"
      "app.kubernetes.io/name"    = "notes-api"
      "app.kubernetes.io/part-of" = "notes-app"
      "app.kubernetes.io/version" = var.api_image_tag
      environment                 = var.environment
    }
    annotations = {
      "app.kubernetes.io/source-repo" = "https://github.com/mukeshappcel2026-cpu/notes-app"
      "app.kubernetes.io/revision"    = var.api_image_tag
    }
  }

  spec {
    replicas = var.api_replicas

    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_surge       = "1"
        max_unavailable = "0"
      }
    }

    selector {
      match_labels = { app = "notes-api" }
    }

    template {
      metadata {
        labels = {
          app                         = "notes-api"
          "app.kubernetes.io/name"    = "notes-api"
          "app.kubernetes.io/part-of" = "notes-app"
          "app.kubernetes.io/version" = var.api_image_tag
          environment                 = var.environment
        }
      }

      spec {
        service_account_name = kubernetes_service_account.api.metadata[0].name

        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "topology.kubernetes.io/zone"
          when_unsatisfiable = "DoNotSchedule"
          label_selector {
            match_labels = { app = "notes-api" }
          }
        }

        container {
          name  = "notes-api"
          image = "${aws_ecr_repository.notes_app.repository_url}:${var.api_image_tag}"

          port {
            container_port = 3000
            protocol       = "TCP"
          }

          env {
            name  = "NODE_ENV"
            value = var.environment == "prod" ? "production" : "development"
          }
          env {
            name  = "PORT"
            value = "3000"
          }
          env {
            name  = "DYNAMODB_TABLE"
            value = aws_dynamodb_table.notes.name
          }
          env {
            name  = "S3_BUCKET"
            value = aws_s3_bucket.assets.id
          }
          env {
            name = "REDIS_HOST"
            value_from {
              config_map_key_ref {
                name = kubernetes_config_map.config.metadata[0].name
                key  = "redis-host"
              }
            }
          }
          env {
            name = "GOOGLE_CLIENT_ID"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.app.metadata[0].name
                key  = "google-client-id"
              }
            }
          }
          env {
            name = "JWT_SECRET"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.app.metadata[0].name
                key  = "jwt-secret"
              }
            }
          }

          env_from {
            config_map_ref {
              name = kubernetes_config_map.feature_flags.metadata[0].name
            }
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "250m"
              memory = "256Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 3000
            }
            initial_delay_seconds = 10
            period_seconds        = 15
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = 3000
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
        }
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Deployment: notes-worker
# ---------------------------------------------------------------------------

resource "kubernetes_deployment" "worker" {
  wait_for_rollout = false

  metadata {
    name      = "notes-worker"
    namespace = kubernetes_namespace.app.metadata[0].name
    labels = {
      app                         = "notes-worker"
      "app.kubernetes.io/name"    = "notes-worker"
      "app.kubernetes.io/part-of" = "notes-app"
      "app.kubernetes.io/version" = var.worker_image_tag
      environment                 = var.environment
    }
  }

  spec {
    replicas = var.worker_replicas

    selector {
      match_labels = { app = "notes-worker" }
    }

    template {
      metadata {
        labels = {
          app                         = "notes-worker"
          "app.kubernetes.io/name"    = "notes-worker"
          "app.kubernetes.io/part-of" = "notes-app"
          "app.kubernetes.io/version" = var.worker_image_tag
          environment                 = var.environment
        }
      }

      spec {
        service_account_name = kubernetes_service_account.worker.metadata[0].name

        container {
          name  = "notes-worker"
          image = "${aws_ecr_repository.notes_worker.repository_url}:${var.worker_image_tag}"

          env {
            name  = "NODE_ENV"
            value = var.environment == "prod" ? "production" : "development"
          }
          env {
            name  = "SQS_QUEUE_URL"
            value = aws_sqs_queue.events.url
          }
          env {
            name  = "DYNAMODB_TABLE"
            value = aws_dynamodb_table.notes.name
          }
          env {
            name  = "S3_BUCKET"
            value = aws_s3_bucket.assets.id
          }
          env {
            name = "REDIS_HOST"
            value_from {
              config_map_key_ref {
                name = kubernetes_config_map.config.metadata[0].name
                key  = "redis-host"
              }
            }
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "150m"
              memory = "128Mi"
            }
          }
        }
      }
    }
  }
}

# ---------------------------------------------------------------------------
# StatefulSet: Redis
# ---------------------------------------------------------------------------

resource "kubernetes_deployment" "redis" {
  wait_for_rollout = false

  metadata {
    name      = "redis"
    namespace = kubernetes_namespace.app.metadata[0].name
    labels = {
      app                         = "redis"
      "app.kubernetes.io/name"    = "redis"
      "app.kubernetes.io/part-of" = "notes-app"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = { app = "redis" }
    }

    template {
      metadata {
        labels = {
          app                         = "redis"
          "app.kubernetes.io/name"    = "redis"
          "app.kubernetes.io/part-of" = "notes-app"
        }
      }

      spec {
        container {
          name  = "redis"
          image = "redis:7.2-alpine"

          port { container_port = 6379 }

          volume_mount {
            name       = "redis-data"
            mount_path = "/data"
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              cpu    = "150m"
              memory = "128Mi"
            }
          }
        }

        volume {
          name = "redis-data"
          empty_dir {}
        }
      }
    }
  }
}

# ---------------------------------------------------------------------------
# Services
# ---------------------------------------------------------------------------

resource "kubernetes_service" "redis" {
  metadata {
    name      = "redis"
    namespace = kubernetes_namespace.app.metadata[0].name
    labels    = { app = "redis", "app.kubernetes.io/part-of" = "notes-app" }
  }

  spec {
    selector   = { app = "redis" }
    cluster_ip = "None"
    port {
      port        = 6379
      target_port = 6379
    }
  }
}

resource "kubernetes_service" "api" {
  metadata {
    name      = "notes-api-svc"
    namespace = kubernetes_namespace.app.metadata[0].name
    labels    = { app = "notes-api", "app.kubernetes.io/part-of" = "notes-app" }
  }

  spec {
    selector = { app = "notes-api" }
    type     = "NodePort"
    port {
      port        = 80
      target_port = 3000
      node_port   = 30080
      protocol    = "TCP"
    }
  }
}

# ---------------------------------------------------------------------------
# Ingress (ALB Ingress Controller)
# ---------------------------------------------------------------------------

resource "kubernetes_ingress_v1" "api" {
  metadata {
    name      = "notes-api-ingress"
    namespace = kubernetes_namespace.app.metadata[0].name
    labels    = { app = "notes-api", "app.kubernetes.io/part-of" = "notes-app" }
    annotations = {
      "kubernetes.io/ingress.class"                                = "alb"
      "alb.ingress.kubernetes.io/scheme"                           = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"                      = "ip"
      "alb.ingress.kubernetes.io/load-balancer-arn"                = aws_lb.alb.arn
      "alb.ingress.kubernetes.io/listen-ports"                     = "[{\"HTTP\": 80}]"
      "alb.ingress.kubernetes.io/healthcheck-path"                 = "/health"
      "alb.ingress.kubernetes.io/healthcheck-interval-seconds"     = "15"
      "alb.ingress.kubernetes.io/subnets"                          = join(",", aws_subnet.public[*].id)
      "alb.ingress.kubernetes.io/security-groups"                  = aws_security_group.alb.id
    }
  }

  spec {
    ingress_class_name = "alb"

    rule {
      host = var.domain_name
      http {
        path {
          path      = "/api"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.api.metadata[0].name
              port { number = 80 }
            }
          }
        }
        path {
          path      = "/health"
          path_type = "Exact"
          backend {
            service {
              name = kubernetes_service.api.metadata[0].name
              port { number = 80 }
            }
          }
        }
      }
    }

    tls {
      hosts       = [var.domain_name]
      secret_name = "notes-tls-cert"
    }
  }
}

# ---------------------------------------------------------------------------
# Horizontal Pod Autoscalers
# ---------------------------------------------------------------------------

resource "kubernetes_horizontal_pod_autoscaler_v2" "api" {
  metadata {
    name      = "notes-api-hpa"
    namespace = kubernetes_namespace.app.metadata[0].name
  }

  spec {
    min_replicas = 2
    max_replicas = 4

    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment.api.metadata[0].name
    }

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = 70
        }
      }
    }

    metric {
      type = "Resource"
      resource {
        name = "memory"
        target {
          type                = "Utilization"
          average_utilization = 80
        }
      }
    }
  }
}

resource "kubernetes_horizontal_pod_autoscaler_v2" "worker" {
  metadata {
    name      = "notes-worker-hpa"
    namespace = kubernetes_namespace.app.metadata[0].name
  }

  spec {
    min_replicas = 1
    max_replicas = 3

    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment.worker.metadata[0].name
    }

    metric {
      type = "Resource"
      resource {
        name = "cpu"
        target {
          type                = "Utilization"
          average_utilization = 75
        }
      }
    }
  }
}
