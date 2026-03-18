# Infra Chart

Umbrella Helm chart for Teknoir infrastructure.

## Secret Management

Secrets in this chart are NOT managed directly by Helm templates anymore. They must be generated, deployed, and managed separately using the existing scripts in the `scripts/` directory.

### Generating Secrets

Before deploying the infra chart, ensure the following secrets are generated:

1.  **CloudDNS Secret**:
    ```sh
    ./scripts/create-clouddns-secret.sh <PATH_TO_GCP_JSON_KEY>
    ```
2.  **GCR JSON Key Secret**:
    ```sh
    ./scripts/create-gcr-json-key-secret.sh <PATH_TO_GCR_JSON_KEY>
    ```
3.  **Harbor Secrets**:
    ```sh
    ./scripts/gen-harbor-secrets.sh
    ```
4.  **Keycloak DB Secret**:
    ```sh
    ./scripts/gen-keycloak-db-secret.sh
    ```
5.  **OAuth2 Proxy Secrets**:
    ```sh
    ./scripts/gen-oauth2-proxy-secrets.sh
    ```
6.  **OAuth2 Proxy Redis Secret**:
    ```sh
    ./scripts/gen-oauth2-proxy-redis-secret.sh
    ```

### Deploying Secrets

Once generated, you can deploy them using `kubectl apply` on the generated manifest files (e.g., `manifest-harbor-secret.yaml`).

## Domain Cascading

The chart supports a global `domain` setting that cascades down to all sub-charts. You can set it in the top-level `values.yaml` or via `--set global.domain=yourdomain.com`.

```yaml
global:
  domain: yourdomain.com
```

This will automatically configure sub-domains like `auth.yourdomain.com`, `harbor.yourdomain.com`, etc.
