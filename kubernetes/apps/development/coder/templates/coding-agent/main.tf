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
  # Published by CI to the Forgejo registry, not the plain-HTTP zot LB:
  # cluster nodes reach forgejo.beaco.works over envoy-internal with a real
  # cert (machineconfig extraHostEntries), whereas 172.16.87.51:5000 is only
  # reachable via a mirror that Spegel shadows, so zot-only images fail to
  # pull. See the coding-agent-oci image in the NixOS flake.
  default = "forgejo.beaco.works/infrastructure/nix-fleet/coding-agent:latest"
}

variable "home_disk_size" {
  type    = string
  default = "50Gi"
}

variable "agent_secret_name" {
  type    = string
  default = "coder-workspace-agent"
}

variable "git_ssh_secret_name" {
  type    = string
  default = "coder-workspace-git-ssh"
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
    GIT_SSH_COMMAND     = "ssh -F /home/coder/.ssh/config -i /home/coder/.ssh/runtime/id_ed25519 -o UserKnownHostsFile=/home/coder/.ssh/known_hosts -o StrictHostKeyChecking=yes"
  }

  startup_script = <<-EOT
    set -e
    mkdir -p /home/coder/workspace

    install_secret() {
      source="/run/coder-agent-secrets/$1"
      target="$2"
      if [ -f "$source" ]; then
        install -D -m 0600 "$source" "$target"
      fi
    }

    install_secret CLAUDE_CREDENTIALS_JSON /home/coder/.claude/.credentials.json
    install_secret CODEX_AUTH_JSON /home/coder/.codex/auth.json
    install_secret OPENCODE_AUTH_JSON /home/coder/.local/share/opencode/auth.json
    install_secret GH_HOSTS_YML /home/coder/.config/gh/hosts.yml
    install_secret FORGEJO_GIT_CREDENTIALS /home/coder/.config/git/credentials
    git config --global credential.https://forgejo.beaco.works.helper 'store --file /home/coder/.config/git/credentials'

    if [ -f /run/coder-git-ssh/id_ed25519 ]; then
      install -d -m 0700 /home/coder/.ssh/runtime
      install -m 0600 /run/coder-git-ssh/id_ed25519 /home/coder/.ssh/runtime/id_ed25519
      if [ -f /run/coder-git-ssh/id_ed25519.pub ]; then
        install -m 0644 /run/coder-git-ssh/id_ed25519.pub /home/coder/.ssh/runtime/id_ed25519.pub
      else
        ssh-keygen -y -f /home/coder/.ssh/runtime/id_ed25519 > /home/coder/.ssh/runtime/id_ed25519.pub
        chmod 0644 /home/coder/.ssh/runtime/id_ed25519.pub
      fi
    fi
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
      args              = ["/bin/coder-agent", "agent"]

      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.main.token
      }

      env {
        name  = "CODER_AGENT_AUTH"
        value = "token"
      }

      env {
        name  = "CODER_AGENT_URL"
        value = "https://code.beaco.works/"
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

      volume_mount {
        name       = "ssh-home"
        mount_path = "/home/coder/.ssh/runtime"
      }

      dynamic "volume_mount" {
        for_each = var.git_ssh_secret_name == "" ? [] : [var.git_ssh_secret_name]
        content {
          name       = "git-ssh-secret"
          mount_path = "/run/coder-git-ssh"
          read_only  = true
        }
      }

      dynamic "volume_mount" {
        for_each = var.agent_secret_name == "" ? [] : [var.agent_secret_name]
        content {
          name       = "agent-secrets"
          mount_path = "/run/coder-agent-secrets"
          read_only  = true
        }
      }
    }

    volume {
      name = "home"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim.home.metadata[0].name
      }
    }

    volume {
      name = "ssh-home"
      empty_dir {}
    }

    dynamic "volume" {
      for_each = var.git_ssh_secret_name == "" ? [] : [var.git_ssh_secret_name]
      content {
        name = "git-ssh-secret"
        secret {
          secret_name = volume.value
        }
      }
    }

    dynamic "volume" {
      for_each = var.agent_secret_name == "" ? [] : [var.agent_secret_name]
      content {
        name = "agent-secrets"
        secret {
          secret_name = volume.value
        }
      }
    }
  }
}
