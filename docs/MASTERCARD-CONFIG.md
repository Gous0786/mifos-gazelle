# Mastercard CBS Connector Configuration

## Configuration File: config.ini

The Mastercard CBS connector is configured in `config/config.ini` under the `[mastercard-demo]` section.

### Configuration Options

```ini
[mastercard-demo]
# Enable or disable mastercard-demo deployment
enabled = true

# Kubernetes namespace for Mastercard CBS
MASTERCARD_NAMESPACE = mastercard-demo

# Repository settings
MASTERCARD_REPO_DIR = mastercard
MASTERCARD_BRANCH = phee-351
MASTERCARD_REPO_LINK = https://github.com/openMF/ph-ee-connector-mccbs.git

# Local CBS connector directory (required)
MASTERCARD_CBS_HOME = $HOME/ph-ee-connector-mccbs

# Use mock API simulator (true) or real Mastercard sandbox (false)
MASTERCARD_USE_MOCK = true

# Mastercard API URL (empty = auto-detect based on use_mock)
# For sandbox: https://sandbox.api.mastercard.com
MASTERCARD_API_URL =

# Enable local development mode (hostPath mounting for hot reload)
# Set to true for local development, false for production
MASTERCARD_LOCALDEV_ENABLED = false
```

## Production Deployment

**config.ini:**
```ini
[mastercard-demo]
enabled = true
MASTERCARD_LOCALDEV_ENABLED = false
```

**Deploy:**
```bash
cd ~/mifos-gazelle
sudo ./run.sh -a mastercard-demo
```

**What happens:**
- Uses built connector image: `ph-ee-connector-mastercard-cbs:1.0.0`
- No hostPath mounting
- Container runs the pre-built image

## Local Development Deployment

**config.ini:**
```ini
[mastercard-demo]
enabled = true
MASTERCARD_LOCALDEV_ENABLED = true
MASTERCARD_CBS_HOME = $HOME/ph-ee-connector-mccbs
```

**Deploy:**
```bash
cd ~/mifos-gazelle
sudo ./run.sh -a mastercard-demo
```

**What happens:**
- Uses JDK image: `eclipse-temurin:17`
- Mounts `~/ph-ee-connector-mccbs` as hostPath at `/app`
- Runs JAR from `/app/build/libs/ph-ee-connector-mastercard-cbs-1.0.0-SNAPSHOT.jar`
- Enables hot reload: edit → rebuild → restart pod

## Development Workflow

### 1. Enable LocalDev Mode

Edit `~/mifos-gazelle/config/config.ini`:
```ini
MASTERCARD_LOCALDEV_ENABLED = true
```

### 2. Deploy with LocalDev

```bash
cd ~/mifos-gazelle
sudo ./run.sh -a mastercard-demo -f ~/tomconfig.ini
```

### 3. Make Code Changes

```bash
# Edit Java files
cd ~/ph-ee-connector-mccbs
vim src/main/java/org/mifos/connector/mastercard/zeebe/MastercardCbsWorkers.java

# Rebuild JAR
./gradlew bootJar

# Restart pod to pick up changes
kubectl delete pod -n mastercard-demo -l app=ph-ee-connector-mastercard-cbs

# Watch logs
kubectl logs -n mastercard-demo -l app=ph-ee-connector-mastercard-cbs -f
```

### 4. Return to Production Mode

Edit `~/mifos-gazelle/config/config.ini`:
```ini
MASTERCARD_LOCALDEV_ENABLED = false
```

Redeploy:
```bash
cd ~/mifos-gazelle
sudo ./run.sh -a mastercard-demo -f ~/tomconfig.ini
```

## Configuration Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `enabled` | `true` | Enable/disable entire mastercard-demo deployment |
| `MASTERCARD_NAMESPACE` | `mastercard-demo` | Kubernetes namespace |
| `MASTERCARD_CBS_HOME` | `$HOME/ph-ee-connector-mccbs` | Local source code directory |
| `MASTERCARD_USE_MOCK` | `true` | Use mock simulator or real Mastercard API |
| `MASTERCARD_API_URL` | (auto) | Override API URL (auto-detects if empty) |
| `MASTERCARD_LOCALDEV_ENABLED` | `false` | Enable local development mode |

## How It Works

When `MASTERCARD_LOCALDEV_ENABLED = true`:

1. **Image Override**: `mastercard.sh` sets `image.repository` to `eclipse-temurin` and `image.tag` to `17`

2. **Custom Resource Generation**: Adds `localdev` section to the Custom Resource:
   ```yaml
   spec:
     localdev:
       enabled: true
       hostPath: "/home/tdaly/ph-ee-connector-mccbs"
       jarPath: "/app/build/libs/ph-ee-connector-mastercard-cbs-1.0.0-SNAPSHOT.jar"
   ```

3. **Operator Reconciliation**: The operator's `reconcile.sh` detects `spec.localdev.enabled: true` and:
   - Mounts hostPath as volume
   - Adds volume mount at `/app`
   - Overrides command to run JAR

## Comparison with Other Config Files

### For Other PHEE Components (Helm-based)

Uses `src/utils/localdev/localdev.ini`:
```ini
[channel]
directory = ${gazelle-home}/repos/ph_template/helm/ph-ee-engine/connector-channel
image = eclipse-temurin:17
jarpath = /app/build/libs/ph-ee-connector-channel-2.0.0.mifos-SNAPSHOT.jar
hostpath = ${HOME}/ph-ee-connector-channel
```

Then run: `./localdev.py channel`

### For Mastercard CBS (Operator-based)

Uses `config/config.ini`:
```ini
[mastercard-demo]
MASTERCARD_LOCALDEV_ENABLED = true
MASTERCARD_CBS_HOME = $HOME/ph-ee-connector-mccbs
```

Then run: `sudo ./run.sh -a mastercard-demo`

## Advanced: Custom JAR Path

If you change the JAR name in `build.gradle`, update `MASTERCARD_CBS_HOME` or manually edit the Custom Resource after deployment:

```bash
kubectl edit mastercardcbsconnector mastercard-cbs -n mastercard-demo
```

Change:
```yaml
spec:
  localdev:
    jarPath: "/app/build/libs/my-custom-name.jar"
```

## Troubleshooting

### Check Current Configuration

```bash
# Check what Custom Resource was deployed
kubectl get mastercardcbsconnector mastercard-cbs -n mastercard-demo -o yaml

# Check if localdev is enabled
kubectl get mastercardcbsconnector mastercard-cbs -n mastercard-demo -o jsonpath='{.spec.localdev.enabled}'
```

### Verify Image

```bash
# Should show eclipse-temurin:17 for localdev, ph-ee-connector-mastercard-cbs:1.0.0 for production
kubectl get pod -n mastercard-demo -l app=ph-ee-connector-mastercard-cbs -o jsonpath='{.items[0].spec.containers[0].image}'
```

### Check HostPath Mount

```bash
kubectl describe pod -n mastercard-demo -l app=ph-ee-connector-mastercard-cbs | grep -A10 "Volumes:"
```

Should show:
```
Volumes:
  local-code:
    Type:          HostPath (bare host directory volume)
    Path:          /home/tdaly/ph-ee-connector-mccbs
```

### Force Redeployment

If changing config doesn't take effect:

```bash
# Delete the Custom Resource
kubectl delete mastercardcbsconnector mastercard-cbs -n mastercard-demo

# Wait for cleanup
sleep 10

# Redeploy
cd ~/mifos-gazelle
sudo ./run.sh -a mastercard-demo -f ~/tomconfig.ini
```

## Summary

**Production:**
```ini
MASTERCARD_LOCALDEV_ENABLED = false
```
→ Uses built image, no hostPath

**Local Development:**
```ini
MASTERCARD_LOCALDEV_ENABLED = true
```
→ Uses JDK image, mounts source code, runs local JAR

**Workflow:**
```bash
Edit config.ini → sudo ./run.sh -a mastercard-demo → edit code → ./gradlew bootJar → kubectl delete pod
```

---

**Document Created:** January 26, 2026
**Configuration File:** `config/config.ini` section `[mastercard-demo]`
**Deployment Script:** `src/deployer/mastercard.sh` (lines 176-221)
**See Also:**
- [docs/MASTERCARD-LOCALDEV.md](MASTERCARD-LOCALDEV.md) - Detailed localdev guide
- [docs/MASTERCARD-CBS-INTEGRATION.md](MASTERCARD-CBS-INTEGRATION.md) - Full integration guide
