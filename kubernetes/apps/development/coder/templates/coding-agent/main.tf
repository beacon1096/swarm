terraform {
  required_providers {
    coder = {
      source = "coder/coder"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
    }
  }
}

variable "namespace" {
  type    = string
  default = "development"
}

variable "image" {
  type    = string
  default = "172.16.87.51:5000/infrastructure/nix-fleet/coding-agent:latest"
}

variable "home_disk_size" {
  type    = string
  default = "50Gi"
}

variable "agent_secret_name" {
  type    = string
  default = ""
}

variable "cpu_request" {
  type    = string
  default = "500m"
}

variable "memory_request" {
  type    = string
  default = "2Gi"
}

variable "memory_limit" {
  type    = string
  default = "8Gi"
}

data "coder_workspace" "me" {}

data "coder_workspace_owner" "me" {}

locals {
  workspace_slug = lower(replace(data.coder_workspace.me.name, "/[^a-zA-Z0-9-]/", "-"))
  owner_slug     = lower(replace(data.coder_workspace_owner.me.name, "/[^a-zA-Z0-9-]/", "-"))
  app            = "coder-${local.owner_slug}-${local.workspace_slug}"
}

resource "coder_agent" "main" {
  arch = "amd64"
  os   = "linux"
  dir  = "/home/coder/workspace"

  env = {
    CODER_WORKSPACE_DIR = "/home/coder/workspace"
  }

  startup_script = <<-EOT
    set -e
    mkdir -p /home/coder/workspace
  EOT
}

resource "coder_app" "opencode" {
  agent_id     = coder_agent.main.id
  slug         = "opencode"
  display_name = "OpenCode"
  url          = "http://localhost:4096"
  share        = "owner"
}

resource "kubernetes_persistent_volume_claim" "home" {
  metadata {
    name      = "${local.app}-home"
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"       = "coder-workspace"
      "app.kubernetes.io/instance"   = local.app
      "coder.com/workspace-id"       = data.coder_workspace.me.id
      "coder.com/workspace-owner-id" = data.coder_workspace_owner.me.id
    }
  }

  spec {
    access_modes = ["ReadWriteOnce"]
    resources {
      requests = {
        storage = var.home_disk_size
      }
    }
  }

  wait_until_bound = false
}

resource "kubernetes_pod" "workspace" {
  count = data.coder_workspace.me.start_count

  metadata {
    name      = local.app
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"       = "coder-workspace"
      "app.kubernetes.io/instance"   = local.app
      "coder.com/workspace-id"       = data.coder_workspace.me.id
      "coder.com/workspace-owner-id" = data.coder_workspace_owner.me.id
    }
  }

  spec {
    restart_policy = "Never"

    container {
      name              = "dev"
      image             = var.image
      image_pull_policy = "Always"
      args              = ["/bin/bash", "-lc", coder_agent.main.init_script]

      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.main.token
      }

      env {
        name  = "CODER_WORKSPACE_DIR"
        value = "/home/coder/workspace"
      }

      dynamic "env_from" {
        for_each = var.agent_secret_name == "" ? [] : [var.agent_secret_name]
        content {
          secret_ref {
            name     = env_from.value
            optional = true
          }
        }
      }

      resources {
        requests = {
          cpu    = var.cpu_request
          memory = var.memory_request
        }
        limits = {
          memory = var.memory_limit
        }
      }

      volume_mount {
        name       = "home"
        mount_path = "/home/coder"
      }
    }

    volume {
      name = "home"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim.home.metadata[0].name
      }
    }
  }
}
