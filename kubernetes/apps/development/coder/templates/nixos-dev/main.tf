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
  type = string
  # Same NixOS image as the coding-agent template, published by CI to the
  # Forgejo registry (nodes can't pull the plain-HTTP zot LB). It bakes
  # code-server (nix-native, patchelf'd) plus nix-ld for foreign binaries.
  #
  # NOTE: Spegel serves cached tag->digest mappings peer-to-peer, so a
  # freshly pushed `:latest` can resolve to a stale digest cluster-wide even
  # with imagePullPolicy=Always. Pin `@sha256:...` here if you need a
  # specific build to land deterministically.
  default = "forgejo.beaco.works/infrastructure/nix-fleet/coding-agent:latest"
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
  # The image's Home Manager profile bin — where code-server and the rest of
  # the toolchain live. The entrypoint already puts this on PATH, but the
  # startup script prepends it defensively in case the agent resets PATH.
  hm_bin = "/home/coder/.local/state/nix/profiles/home-manager/home-path/bin"
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
    export PATH="${local.hm_bin}:$PATH"
    mkdir -p /home/coder/workspace

    # code-server (nix-native). --auth none: Coder fronts auth + TLS.
    code-server \
      --auth none \
      --bind-addr 127.0.0.1:13337 \
      --disable-telemetry \
      /home/coder/workspace \
      >/home/coder/.code-server.log 2>&1 &
  EOT
}

resource "coder_app" "code-server" {
  agent_id     = coder_agent.main.id
  slug         = "code-server"
  display_name = "code-server"
  icon         = "/icon/code.svg"
  url          = "http://localhost:13337/?folder=/home/coder/workspace"
  subdomain    = false
  share        = "owner"

  healthcheck {
    url       = "http://localhost:13337/healthz"
    interval  = 5
    threshold = 6
  }
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
    # Redundant (3-replica) Longhorn for the persistent home — code and data
    # live here. Only affects NEW workspaces; storageClassName is immutable
    # on an existing PVC.
    storage_class_name = "longhorn-r3"
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
