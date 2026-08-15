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
  default = "coder-workspace-agent"
}

variable "git_ssh_secret_name" {
  type    = string
  default = "coder-workspace-git-ssh"
}

variable "infra_secret_name" {
  type    = string
  default = "coder-workspace-infra"
}

variable "tailscale_auth_key_expires_at" {
  type    = string
  default = "2026-11-03T00:00:00Z"

  validation {
    condition     = can(timecmp(var.tailscale_auth_key_expires_at, "2026-01-01T00:00:00Z"))
    error_message = "tailscale_auth_key_expires_at must be an RFC 3339 timestamp."
  }
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
    GIT_SSH_COMMAND     = "ssh -F /home/coder/.ssh/config -i /home/coder/.ssh/runtime/id_ed25519 -o UserKnownHostsFile=/home/coder/.ssh/known_hosts -o StrictHostKeyChecking=yes"
    KUBECONFIG          = "/run/coder-infra/kubeconfig"
    SOPS_AGE_KEY_FILE   = "/run/coder-infra/sops-age-keys"
    TALOSCONFIG         = "/run/coder-infra/talosconfig"
  }

  startup_script = <<-EOT
    set -e
    export PATH="${local.hm_bin}:$PATH"
    mkdir -p /home/coder/workspace

    install_secret() {
      source="/run/coder-agent-secrets/$1"
      target="$2"
      if [ -f "$source" ]; then
        install -D -m 0600 "$source" "$target"
      fi
    }

    install_secret CLAUDE_CREDENTIALS_JSON /home/coder/.claude/.credentials.json
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

  lifecycle {
    precondition {
      condition = (
        var.agent_secret_name == "" ||
        timecmp(timestamp(), var.tailscale_auth_key_expires_at) < 0
      )
      error_message = "The Tailscale auth key has expired; rotate the Kubernetes Secret and update tailscale_auth_key_expires_at."
    }
  }
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

      env {
        name  = "KUBECONFIG"
        value = "/run/coder-infra/kubeconfig"
      }

      env {
        name  = "SOPS_AGE_KEY_FILE"
        value = "/run/coder-infra/sops-age-keys"
      }

      env {
        name  = "TALOSCONFIG"
        value = "/run/coder-infra/talosconfig"
      }

      env {
        name  = "TS_HOSTNAME"
        value = trim(substr(local.app, 0, 63), "-")
      }

      dynamic "env" {
        for_each = var.agent_secret_name == "" ? [] : [var.agent_secret_name]
        content {
          name = "TS_AUTHKEY"
          value_from {
            secret_key_ref {
              name     = env.value
              key      = "TS_AUTHKEY"
              optional = false
            }
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

      dynamic "volume_mount" {
        for_each = var.infra_secret_name == "" ? [] : [var.infra_secret_name]
        content {
          name       = "infra-secrets"
          mount_path = "/run/coder-infra"
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

    dynamic "volume" {
      for_each = var.infra_secret_name == "" ? [] : [var.infra_secret_name]
      content {
        name = "infra-secrets"
        secret {
          secret_name = volume.value
        }
      }
    }
  }
}
