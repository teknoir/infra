# devhost-ci: secrets inventory (names only, never values)

Every value is created by hand (or piped cluster to cluster) and never committed. Rotation is in plans/cicd/proposal-v4.md 6.1.

| Secret | Keys | Holds | Created by | Rotation |
|---|---|---|---|---|
| `arc-runners/arc-github` | `github_token` | Fine-grained PAT `arc-devhost-ci` (owner teknoir; org: Self-hosted runners RW, Administration R) | Anders creates the PAT; Opus creates the Secret from the `request_secret` file in the same command | Yearly; Anders renews, Opus re-applies |
| `arc-runners/harbor-push` | `username`, `password` | Harbor robot `devhost-ci` (push and pull on project `teknoir`) | harbor-config writes r415 `teknoir-system/harbor-devhost-ci`; Opus pipes it here | 365 days; delete the r415 Secret so harbor-config re-mints, then pipe again |
| `kube-system/argocd-manager-long-lived-token` | `token`, `ca.crt` | ServiceAccount `argocd-manager` (cluster-admin, `argocd-manager.yaml`): r415 ArgoCD's identity here (CI v4 P6.3) | Kubernetes fills it after `kubectl --context devhost-ci apply -f clusters/devhost-ci/argocd-manager.yaml`; Opus pipes token + CA into r415 `teknoir-system/cluster-devhost-ci` | Delete it, re-apply, pipe again |
| `kube-system/k3s-serving`, node token, `/etc/rancher/k3s/k3s.yaml` | k3s internals | k3s | k3s | `k3s certificate rotate` |

Kubeconfig: `~/.kube/config` context `devhost-ci` (user `anders`, mode 0600). Never print or copy it.
