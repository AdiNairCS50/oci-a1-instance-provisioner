# OCI A1 Auto-Provisioner

Polls Oracle Cloud every 10 minutes via GitHub Actions until an Always Free
Ampere A1 instance (4 OCPU / 24 GB RAM) becomes available. When it succeeds,
it opens a GitHub Issue with the public IP and disables itself.

## Repo structure

```
.github/workflows/provision.yml   — GitHub Actions workflow (runs every 10 min)
provision.sh                      — OCI CLI provisioning script
```

## One-time setup

### Step 1 — OCI API key

If you set up OCI via Cloud Shell, you do not yet have an API key. You need one
for headless access from GitHub Actions.

1. OCI Console → top-right profile menu → **User settings**
2. **API Keys → Add API Key → Generate API Key Pair**
3. Download the private key (.pem file) — you will need its contents shortly
4. Copy the config snippet shown (it contains your fingerprint and tenancy OCID)

### Step 2 — Find all required values

| Secret name | Where to find it |
|---|---|
| `OCI_USER_OCID` | Profile menu → User settings → OCID field |
| `OCI_TENANCY_OCID` | Profile menu → Tenancy → OCID field |
| `OCI_FINGERPRINT` | User settings → API Keys → fingerprint column |
| `OCI_REGION` | Region identifier shown in the console URL, e.g. `us-ashburn-1` |
| `OCI_KEY_PEM` | Full contents of the .pem file you downloaded in Step 1 |
| `OCI_COMPARTMENT_ID` | Identity & Security → Compartments → root compartment OCID |
| `OCI_SUBNET_ID` | Networking → Virtual Cloud Networks → your VCN → Subnets → any subnet OCID |
| `OCI_IMAGE_ID` | Compute → Images → Platform images → search "Canonical Ubuntu" → pick **22.04 Minimal aarch64** → OCID |
| `OCI_AVAILABILITY_DOMAINS` | Identity → Availability Domains → copy all names, comma-separated (see below) |
| `SSH_PUBLIC_KEY` | Contents of `~/.ssh/id_ed25519.pub` or `~/.ssh/id_rsa.pub` on your Mac |

**Finding availability domain names:**

In OCI Cloud Shell or locally with the OCI CLI, run:
```bash
oci iam availability-domain list --compartment-id <your-tenancy-ocid> --query 'data[].name' --raw-output
```

The output looks like:
```
["IYuH:US-ASHBURN-AD-1","IYuH:US-ASHBURN-AD-2","IYuH:US-ASHBURN-AD-3"]
```

Enter all of them as the secret value, comma-separated:
```
IYuH:US-ASHBURN-AD-1,IYuH:US-ASHBURN-AD-2,IYuH:US-ASHBURN-AD-3
```

The script tries each one in order until it finds capacity.

### Step 3 — Add secrets to GitHub

1. In this repo: **Settings → Secrets and variables → Actions**
2. Click **New repository secret** for each row in the table above

### Step 4 — Enable and trigger

1. Go to the **Actions** tab
2. Click **OCI A1 Instance Provisioner → Run workflow** to trigger a manual test run
3. Watch the logs — expected output when capacity is unavailable:
   ```
   No capacity in AD-1 — trying next
   No capacity in AD-2 — trying next
   No capacity in AD-3 — trying next
   Will retry on next schedule run.
   ```
4. The workflow then runs automatically every 10 minutes with no further action needed

### Step 5 — When it succeeds

GitHub opens an Issue in this repo with the public IP address and disables the
workflow automatically. You will receive a GitHub notification.

SSH in with:
```bash
ssh ubuntu@<public-ip-from-issue>
```

## Always Free limits enforced by the script

| Rule | Enforced how |
|---|---|
| Shape: `VM.Standard.A1.Flex` only | Hardcoded constant — cannot be overridden by env vars |
| OCPUs: max 4 | Hardcoded constant + pre-flight quota check aborts if already at limit |
| Memory: max 24 GB | Hardcoded constant |
| Boot volume: 47 GB | Hardcoded to OCI minimum — fits within 200 GB free storage quota |
| Idempotent | Checks for existing `pmtradingbot` instance before attempting launch |
| Tagged | `FreeTier=true` freeform tag applied to the instance |

## Stopping the workflow manually

Actions tab → **OCI A1 Instance Provisioner** → top-right **...** menu → **Disable workflow**
