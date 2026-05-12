<!-- SPECKIT START -->
For additional context about technologies to be used, project structure,
shell commands, and other important information, read the current plan
<!-- SPECKIT END -->

## Cluster Credentials

- Kubernetes kubeconfig for the talos-ii cluster is at `./kubeconfig`.
  Use it explicitly, for example: `KUBECONFIG=/home/beacon/swarm/kubeconfig kubectl ...`.
- Talos client config is at `./talos/clusterconfig/talosconfig`.
  Use it explicitly, for example: `talosctl --talosconfig /home/beacon/swarm/talos/clusterconfig/talosconfig ...`.
- These files are local operator credentials and must stay out of Git; document paths and commands only, never credential contents.
