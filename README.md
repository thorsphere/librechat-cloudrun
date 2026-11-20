# librechat-cloudrun

![GitHub release (latest by date)](https://img.shields.io/github/v/release/thorsphere/librechat-cloudrun)
![GitHub Top Language](https://img.shields.io/github/languages/top/thorsphere/librechat-cloudrun)
![OSS Lifecycle](https://img.shields.io/osslifecycle/thorsphere/librechat-cloudrun)

---

Stateless LibreChat deployment setup optimized for Google Cloud Run with external MongoDB Atlas.

---

This repository deploys LibreChat on Google Cloud Run. The image is rebuilt from a pinned upstream
tag, `librechat.yaml` is baked in at build time, and the six required secrets
are injected from GCP Secret Manager at deploy time. No secret 
touches git or the image. Users and conversations live in MongoDB Atlas, so
instances are disposable and deploys are push-to-`main` via GitHub Actions.

---

## Features

- **Pinned, reproducible image**: multi-stage `Dockerfile` builds a fixed
  LibreChat release (`ARG LIBRECHAT_VERSION`); lean runtime image with pruned
  `node_modules` and jemalloc.
- **Cloud Run-native runtime**: `HOST=0.0.0.0`, `/health` startup probe, and
  exec-form `CMD` so SIGTERM reaches node for graceful shutdown.
- **Secret-free configuration**: `librechat.yaml` uses `${ENV_VAR}`
  interpolation; the six LibreChat secrets live only in GCP Secret Manager and
  are attached as env vars at deploy time.
- **Stateless by design**: users and conversations persist in MongoDB Atlas;
  instance disks are ephemeral and disposable.
- **Push-to-deploy CI/CD**: GitHub Actions builds via Cloud Build and deploys
  to Cloud Run on relevant pushes, authenticated through Workload Identity
  Federation; doc-only changes do not trigger a run.
- **One script, local and CI**:`scripts/deploy.sh` does the same build and
  deploy from a local machine or from the workflow.
- **OpenRouter out of the box**: `librechat.yaml` ships a configured OpenRouter
  endpoint and default models.
- **Documented hardening path**: optional Direct VPC Egress and Cloud NAT with a
  static egress IP shrinks the MongoDB Atlas allow-list to a single address.

---

## How it works

```mermaid
flowchart LR
    push["git push (main)"] --> gha["GitHub Actions"]
    gha --> cb["Cloud Build"]
    cb --> ar["Artifact Registry"]
    ar --> cr["Cloud Run"]
    sm[("Secret Manager")] --> cr
    cr <--> atlas[("MongoDB Atlas")]
```

| Piece | Where it lives |
|---|---|
| LibreChat source | cloned at build time, pinned via `ARG LIBRECHAT_VERSION` in `Dockerfile` |
| App config (endpoint, models) | `librechat.yaml`, baked into the image (no secrets — uses `${ENV_VAR}` interpolation) |
| Secrets | GCP Secret Manager, attached as env vars at deploy time |
| Persistent state (users, chats) | MongoDB Atlas |
| Ephemeral disk | `uploads/`, `logs/` — gone on restart; configure `fileStrategy` for durable files |

---

## Repository layout

| Path | Purpose |
|---|---|
| `Dockerfile` | Multi-stage build of a pinned LibreChat release |
| `librechat.yaml` | LibreChat custom config (OpenRouter endpoint, default models) |
| `cloudbuild.yaml` | Image build spec for Cloud Build |
| `scripts/deploy.sh` | Build + deploy (run locally and by CI) |
| `.github/workflows/deploy.yml` | Deploys to Cloud Run on push to `main` |

---

## Environment variables

Everything the deployment needs, in one place. **Actions** values live in the GitHub repository settings, **Cloud Run** values live in Secret Manager and are attached to the service by `scripts/deploy.sh`, and the rest is baked into the image.

### GitHub Actions — repository variables

*Settings → Secrets and variables → Actions → Variables.* All four are identifiers, not credentials, so plain repo variables are fine (the trust boundary is the WIF attribute condition that pins the repository):

| Name | Value |
|---|---|
| `GOOGLE_WORKLOAD_PROVIDER` | `projects/${PROJECT_NUM}/locations/global/workloadIdentityPools/github-actions/providers/github` |
| `GOOGLE_SERVICE_ACCOUNT` | `github-actions-deployer@thorsphere-ai-prd.iam.gserviceaccount.com` |
| `GOOGLE_PROJECT_ID` | your GCP project id |
| `GOOGLE_REGION` | e.g. `us-central1` |

> Values are literal strings to paste — GitHub Variables do **not** expand
> `${...}`. Where a value shows `${PROJECT_NUM}` or `${GOOGLE_PROJECT_ID}`,
> substitute your real project number / project id (step 5b prints the exact
> `GOOGLE_SERVICE_ACCOUNT` email).

### Cloud Run — runtime env vars (Secret Manager)

`scripts/deploy.sh` attaches these to the service as env vars; create the secrets per step 4. LibreChat requires exactly these six. Everything else has working defaults. Secret Manager names carry a `librechat-` prefix. They are project-scoped, so the prefix keeps them unambiguous if other services share the project (env var names are fixed by LibreChat and stay unprefixed):

| Env var | Secret name | Content |
|---|---|---|
| `MONGO_URI` | `librechat-mongo-uri` | full `mongodb+srv://.../librechat` URI (step 1) |
| `OPENROUTER_API_KEY` | `librechat-openrouter-api-key` | OpenRouter API key (referenced by `librechat.yaml` via `${OPENROUTER_API_KEY}`) |
| `CREDS_KEY` | `librechat-creds-key` | `openssl rand -hex 32` (encrypts stored credentials) |
| `CREDS_IV` | `librechat-creds-iv` | `openssl rand -hex 16` |
| `JWT_SECRET` | `librechat-jwt-secret` | `openssl rand -hex 32` |
| `JWT_REFRESH_SECRET` | `librechat-jwt-refresh-secret` | `openssl rand -hex 32` |

Need another LibreChat env var (e.g. `ALLOW_REGISTRATION`, `SESSION_EXPIRY`)? Add it to the `--set-secrets` list in `scripts/deploy.sh` (or `--update-env-vars` for non-secrets) and redeploy — no image change needed.

### Baked into the image (Dockerfile `ENV`)

| Name | Value | Note |
|---|---|---|
| `NODE_ENV` | `production` | runs LibreChat in production mode |
| `HOST` | `0.0.0.0` | **required** — LibreChat defaults to `localhost`, which breaks Cloud Run health checks |
| `PORT` | `8080` | default for local runs; Cloud Run injects its own `PORT` and LibreChat reads it |

### Optional overrides for `scripts/deploy.sh`

| Name | Default | Purpose |
|---|---|---|
| `GOOGLE_PROJECT_ID` | current gcloud project | GCP project |
| `GOOGLE_REGION` | `us-central1` | Cloud Run / Artifact Registry region |
| `SERVICE` | `librechat` | Cloud Run service name |
| `AR_REPO` | `librechat` | Artifact Registry repository |
| `IMAGE_NAME` | `librechat` | image name |
| `TAG` | git short SHA | image tag |

---

## Prerequisites

- A GCP project with billing. This guide works two ways to choose from:
  - **CLI (`gcloud`)**: every step is shown as a command. Install the
    [Google Cloud SDK](https://cloud.google.com/sdk/docs/install) and
    authenticate:

    ```bash
    gcloud auth login
    gcloud config set project your-gcp-project
    ```

  - **GCP Console (fully manual)**: no tooling beyond a browser. Each setup
    step that shows `gcloud` commands also has an **"Or manually in the GCP
    Console"** walkthrough right below it, follow those instead. Two numbers
    appear throughout the console steps: the **project id** and the **project
    number** (console: *IAM & Admin → Settings*). The first deploy itself can
    also be done without `gcloud` by pushing to `main` and letting GitHub
    Actions run it.

- Your MongoDB Atlas cluster (done) and OpenRouter API key.
- This repository pushed to GitHub (needed for the CI deploy path).

CLI users: set these once per shell; the commands below use them (console
users just note the values, `PROJECT_NUM` is the project number from
*IAM & Admin → Settings*):

```bash
export GOOGLE_PROJECT_ID=your-gcp-project
export GOOGLE_REGION=us-central1
export PROJECT_NUM=$(gcloud projects describe "$GOOGLE_PROJECT_ID" --format='value(projectNumber)')
```

---

## One-time setup

### 1. MongoDB Atlas (finish)

1. **Database user**: *Database Access → Add New Database User* → password auth, built-in role **"Read and write to any database"** (or `readWrite` limited to the `librechat` database).
2. **Network access**: *Network Access → IP Access List* → allow **`0.0.0.0/0`** — Cloud Run's egress IPs are dynamic. (Harden later with Direct VPC Egress + Cloud NAT for fixed egress IPs — see [Hardening: private egress to MongoDB Atlas](#hardening-private-egress-to-mongodb-atlas).)
3. **Final connection string** — append the database name and URL-encode the password (`@`→`%40`, `/`→`%2F`, `#`→`%23`, `+`→`%2B`):

   ```
   mongodb+srv://USER:PASS@librechat.hvqkthn.mongodb.net/librechat
   ```

   Without the `/librechat` path, Mongoose silently falls back to a database named `test`.

> **The M0 free tier is sufficient.**
> 
> Database users and IP access lists are
> project-level security features available on *every* tier — the free cluster's
> missing "configuration" options (fixed 512 MB storage, no backups, no VPC
> peering) don't affect this setup. Only true private connectivity (VPC Peering
> / PrivateLink) needs a paid tier (M10+); the Direct VPC Egress + Cloud NAT
> option in [Hardening](#hardening-private-egress-to-mongodb-atlas) works on any
> tier (allow-list the NAT's static IPs instead of `0.0.0.0/0`).

### 2. Enable the APIs

```bash
gcloud services enable --project "$GOOGLE_PROJECT_ID" \
  run.googleapis.com artifactregistry.googleapis.com \
  cloudbuild.googleapis.com secretmanager.googleapis.com \
  iamcredentials.googleapis.com
```

Or manually in the **GCP Console**: open *APIs & Services → Library*
([console.cloud.google.com/apis/library](https://console.cloud.google.com/apis/library)),
select the project at the top, search each API by its console name, and click
**Enable**:

| gcloud identifier | Console name |
|---|---|
| `run.googleapis.com` | Cloud Run Admin API |
| `artifactregistry.googleapis.com` | Artifact Registry API |
| `cloudbuild.googleapis.com` | Cloud Build API |
| `secretmanager.googleapis.com` | Secret Manager API |
| `iamcredentials.googleapis.com` | IAM Service Account Credentials API |

(Enabling APIs needs Owner/Editor or `roles/serviceusage.serviceUsageAdmin`
on the project, a greyed-out **Enable** button means missing permission.)

### 3. Artifact Registry (image repository)

```bash
gcloud artifacts repositories create librechat \
  --repository-format=docker --location "$GOOGLE_REGION" --project "$GOOGLE_PROJECT_ID"

# Cloud Build pushes the image; give its runtime SA write access
gcloud projects add-iam-policy-binding "$GOOGLE_PROJECT_ID" \
  --member="serviceAccount:${PROJECT_NUM}@cloudbuild.gserviceaccount.com" \
  --role="roles/artifactregistry.writer"
```

Or manually in the **GCP Console** — two parts:

**Create the repository** — open *Artifact Registry*,
select the project, click **+ CREATE REPOSITORY**, and set:

- Name: `librechat`
- Format: **Docker**
- Location type: **Region** — the same region as `GOOGLE_REGION` (e.g. `us-central1`)
- Mode: **Standard**; encryption: Google-managed (both are defaults)

**Grant Cloud Build push access**: open *IAM & Admin → IAM*,
find the Cloud Build service account `PROJECT_NUM@cloudbuild.gserviceaccount.com`
(it exists once the Cloud Build API from step 2 is enabled; `PROJECT_NUM` is
your numeric project number), click the pencil → **Add another role** →
search **Artifact Registry Writer** → **Save**.

> **Can't find the Cloud Build service account?**
>
> The IAM page hides Google-provided role grants by default, tick
> **"Include Google-provided role grants"** in the filter row. You need the
> **"Legacy Cloud Build Service Account"** (`PROJECT_NUM@cloudbuild.gserviceaccount.com`,
> still the default build executor), *not* **"Cloud Build
> Service Agent"** (`service-PROJECT_NUM@gcp-sa-cloudbuild.iam.gserviceaccount.com`),
> that one is Google's API service agent and never pushes images.

> **Cost tip with cleanup policies:**
>
> Every deploy pushes a new image and Artifact
> Registry bills for stored data. On the repository's *Policies* tab
> (*Artifact Registry → repository → Policies → **Add cleanup policy***),
> consider adding two policies to keep the repo small:
> **"Keep 5 most recent versions"** (keep by count: 5) and
> **"Cleanup untagged older than 7d"** (tag status: untagged, age: 7 days).
> This keeps the last ~5 deploys as Cloud Run rollback targets and auto-prunes
> everything else.

### 4. Secret Manager (the 6 app secrets)

| Secret | Content |
|---|---|
| `librechat-mongo-uri` | full `mongodb+srv://...` URI from step 1 |
| `librechat-openrouter-api-key` | your OpenRouter API key |
| `librechat-creds-key` | `openssl rand -hex 32` (encrypts stored credentials) |
| `librechat-creds-iv` | `openssl rand -hex 16` |
| `librechat-jwt-secret` | `openssl rand -hex 32` |
| `librechat-jwt-refresh-secret` | `openssl rand -hex 32` |

Create each and add its first version:

```bash
create_secret() {
  gcloud secrets create "$1" --replication-policy=automatic --project "$GOOGLE_PROJECT_ID"
  printf '%s' "$2" | gcloud secrets versions add "$1" --data-file=- --project "$GOOGLE_PROJECT_ID"
}

create_secret librechat-mongo-uri          'mongodb+srv://USER:PASS@librechat.hvqkthn.mongodb.net/librechat'
create_secret librechat-openrouter-api-key 'sk-or-...'
create_secret librechat-creds-key          "$(openssl rand -hex 32)"
create_secret librechat-creds-iv           "$(openssl rand -hex 16)"
create_secret librechat-jwt-secret         "$(openssl rand -hex 32)"
create_secret librechat-jwt-refresh-secret "$(openssl rand -hex 32)"
```

Then let the **Cloud Run runtime service account** read them (it needs this to receive them as env vars — without it the service fails at startup):

```bash
for s in librechat-mongo-uri librechat-openrouter-api-key librechat-creds-key librechat-creds-iv librechat-jwt-secret librechat-jwt-refresh-secret; do
  gcloud secrets add-iam-policy-binding "$s" --project "$GOOGLE_PROJECT_ID" \
    --member="serviceAccount:${PROJECT_NUM}-compute@developer.gserviceaccount.com" \
    --role="roles/secretmanager.secretAccessor"
done
```

Or manually in the **GCP Console** in two parts:

**Create the secrets**: open *Secret Manager*,
click **+ CREATE SECRET**, set the name (must match the table above, e.g.
`librechat-mongo-uri`), paste the value, leave replication as *Google-managed* → **CREATE**.
Repeat six times. For the four generated values, run `openssl rand -hex 32`
(`-hex 16` for `librechat-creds-iv`) in a terminal and paste the output.

**Grant access**: open each secret → *Permissions* tab → **+ GRANT ACCESS** →
principal `PROJECT_NUM-compute@developer.gserviceaccount.com` → role
**Secret Manager Secret Accessor** → **SAVE**. Repeat per secret (the CLI loop
above does all six at once).

> **Don't be confused by "Editor (Legacy)"**
>
> On the secret's Permissions tab:
> the Default compute service account already shows an inherited project-level
> *Editor (Legacy)* grant, but among the basic roles only `roles/owner` includes
> `secretmanager.versions.access`, `roles/editor` and `roles/viewer` do **not**. The
> explicit **Secret Manager Secret Accessor** grant above is therefore
> mandatory without it the revision fails at startup with *Permission denied
> on secret*.

> `scripts/deploy.sh` attaches these exact secret names to the service. If you rename one, update the `--set-secrets` list there too.

### 5. GitHub Actions deployer (Workload Identity Federation)

No long-lived JSON keys: GitHub's OIDC token is exchanged for short-lived credentials, restricted to this one repository.

```bash
# 5a. Pool + provider (replace OWNER/REPO with your GitHub owner/repo)
gcloud iam workload-identity-pools create github-actions \
  --location=global --project "$GOOGLE_PROJECT_ID" --display-name="GitHub Actions"

gcloud iam workload-identity-pools providers create-oidc github \
  --workload-identity-pool=github-actions --location=global --project "$GOOGLE_PROJECT_ID" \
  --display-name="GitHub" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository,attribute.repository_owner=assertion.repository_owner" \
  --attribute-condition="assertion.repository=='OWNER/REPO'"

# 5b. Deployer service account + allow GitHub to impersonate it
gcloud iam service-accounts create github-actions-deployer \
  --project "$GOOGLE_PROJECT_ID" --display-name="GitHub Actions deployer (LibreChat)"

DEPLOYER_SA="github-actions-deployer@${GOOGLE_PROJECT_ID}.iam.gserviceaccount.com"

gcloud iam service-accounts add-iam-policy-binding "$DEPLOYER_SA" \
  --project "$GOOGLE_PROJECT_ID" --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUM}/locations/global/workloadIdentityPools/github-actions/attribute.repository/OWNER/REPO"

# 5c. What the deployer may do
for role in roles/run.admin roles/artifactregistry.writer \
            roles/cloudbuild.builds.editor roles/secretmanager.secretAccessor \
            roles/iam.serviceAccountUser; do
  gcloud projects add-iam-policy-binding "$GOOGLE_PROJECT_ID" \
    --member="serviceAccount:${DEPLOYER_SA}" --role="$role"
done
```

Or manually in the **GCP Console** — three parts:

**5a. Pool + provider** — open *IAM & Admin → Workload Identity Federation* →
**CREATE POOL** (name `github-actions`), then in the pool →
**ADD PROVIDER** → **OpenID Connect (OIDC)**: provider name `github`, issuer URL
`https://token.actions.githubusercontent.com`, and under *Provider attributes*
set the mapping:
- `google.subject=assertion.sub`
- `attribute.actor=assertion.actor`
- `attribute.repository=assertion.repository`
- `attribute.repository_owner=assertion.repository_owner`

plus the attribute condition `assertion.repository=='OWNER/REPO'` (replace
OWNER/REPO with your GitHub owner/repo). Unmapped claims can never be used in
IAM conditions or bindings later, so keep the full standard set — `actor` and
`repository_owner` enable future per-user or per-organization restrictions.

**5b. Deployer SA + impersonation** — open *IAM & Admin → Service Accounts* →
**CREATE SERVICE ACCOUNT** (ID `github-actions-deployer`; skip the optional role
grants in the wizard — 5c adds them). Then on the new account's *Principles with access* tab →
**+ GRANT ACCESS** → paste the principal
`principalSet://iam.googleapis.com/projects/${PROJECT_NUM}/locations/global/workloadIdentityPools/github-actions/attribute.repository/OWNER/REPO`
and pick role **Workload Identity User** → **SAVE**.

**5c. Project roles** — open *IAM & Admin → IAM*. A brand-new SA has zero role
bindings, so `github-actions-deployer@${GOOGLE_PROJECT_ID}.iam.gserviceaccount.com`
does not appear in the principal list yet — expected. Click **+ GRANT ACCESS**
(no need to find the account): paste the email into *New principals*, it
resolves although it is not listed, then add all seven roles → **SAVE**:
**Cloud Run Admin**, **Artifact Registry Writer**, **Cloud Build Editor**,
**Secret Manager Secret Accessor**, **Service Account User**, **Service Usage
Admin**, **Storage Admin**. From then on the account shows up in the IAM list
(pencil → *Edit principal* for later changes).

> **Role cheat-sheet** (which role does what):
>
> | Role | Needed for |
> |---|---|
> | Cloud Run Admin | `gcloud run deploy` + service describe |
> | Artifact Registry Writer | push/pull images in the repo |
> | Cloud Build Editor | `gcloud builds submit` (starts the build) |
> | Service Usage Admin | use project services in API calls (`serviceusage.services.use`) |
> | Storage Admin | upload the build source to the `PROJECT_ID_cloudbuild` staging bucket |
> | Secret Manager Secret Accessor | attach the six secrets to the service |
> | Service Account User | deploy with the runtime service account |
>
> Storage Admin + Service Usage Admin are required: `gcloud builds
> submit` uploads the source tarball to `gs://PROJECT_ID_cloudbuild` as the
> *deployer* SA, and a bare **Cloud Build Editor** cannot write that bucket.
> The run fails with *"forbidden from accessing the bucket
> [PROJECT_ID_cloudbuild]"* before any build starts. Editor on the Cloud Build
> service account does **not** cover this (that account only acts *inside* the
> build).

Note: the *Service Accounts* page's permissions control access **to** the SA
(who may impersonate it), not project roles **for** it. The seven roles above
are project-level and must be granted on the IAM page.

### 6. GitHub repository configuration

*Settings → Secrets and variables → Actions → Variables*, add these four (values from step 5); no repository secrets are needed:

| Variable | Value |
|---|---|
| `GOOGLE_WORKLOAD_PROVIDER` | `projects/${PROJECT_NUM}/locations/global/workloadIdentityPools/github-actions/providers/github` |
| `GOOGLE_SERVICE_ACCOUNT` | `github-actions-deployer@thorsphere-ai-prd.iam.gserviceaccount.com` |
| `GOOGLE_PROJECT_ID` | your project id |
| `GOOGLE_REGION` | `us-central1` (or your region) |

---

## First deployment

Either run the script by hand:

```bash
./scripts/deploy.sh
```

or just `git push` to `main` — the workflow builds the image and deploys whenever `Dockerfile`, `librechat.yaml`, `cloudbuild.yaml`, `scripts/**` or the workflow itself changes. Doc-only changes (e.g. `README.md`) never trigger a run; to deploy without changing code, use the **Run workflow** button on the Actions tab (`workflow_dispatch`). CI needs all of steps 1–6 complete (roles, secrets, repo variables) — run `./scripts/deploy.sh` locally first if you want to validate the setup outside CI.

When it finishes:

1. Open the Cloud Run URL (`gcloud run services describe librechat --region "$GOOGLE_REGION" --format='value(status.url)'`).
2. **Open registration** — it is closed unless `ALLOW_REGISTRATION=true` is
   set (no rebuild; the new revision is live within seconds):

   ```bash
   gcloud run services update librechat --region "$GOOGLE_REGION" --update-env-vars ALLOW_REGISTRATION=true
   ```

3. **Register — the first account becomes the admin.**
4. **Close registration again** (while it is open, anyone can sign up):

   ```bash
   gcloud run services update librechat --region "$GOOGLE_REGION" --update-env-vars ALLOW_REGISTRATION=false
   ```

5. Pick the *OpenRouter* endpoint; the default models come from `librechat.yaml`.

---

## Day-2 operations

**Rotate the OpenRouter key** — no rebuild needed:

```bash
printf '%s' 'sk-or-new-key' | gcloud secrets versions add librechat-openrouter-api-key --data-file=- --project "$GOOGLE_PROJECT_ID"
gcloud run services update librechat --region "$GOOGLE_REGION" \
  --update-secrets=OPENROUTER_API_KEY=librechat-openrouter-api-key:latest
```

**Add another user** — repeat the open → sign up → close registration pair
from *First deployment*; it flips on the next revision within seconds.

**Change config or models** — edit `librechat.yaml`, push to `main`. CI rebuilds, since config is baked into the image.

**Upgrade LibreChat** — bump `ARG LIBRECHAT_VERSION` in `Dockerfile` and set the matching `version:` in `librechat.yaml` (the config schema version must match the release), then push.

**Logs**:

```bash
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="librechat"' \
  --project "$GOOGLE_PROJECT_ID" --limit=50
```

---

## Hardening: private egress to MongoDB Atlas

The default setup allow-lists `0.0.0.0/0` in Atlas (step 1.2) because Cloud Run's
egress IPs are dynamic. To shrink the allow-list to a single fixed IP, route the
container's traffic through your own VPC with **Direct VPC Egress** and a
**Cloud NAT** that owns a static IP:

```mermaid
flowchart LR
    cr["Cloud Run (librechat)"] -- "Direct VPC Egress (all-traffic)" --> subnet[["VPC subnet (private)"]]
    subnet --> nat["Cloud NAT (static IP)"]
    nat -- "TLS, public internet" --> atlas[("MongoDB Atlas M0<br/>allow-list: NAT IP + admin /32")]
```

> **What this does and doesn't do.** The Atlas endpoint stays public; what
> changes is *who can reach it*. Only the NAT's static IP (plus whatever else
> you allow-list). The connection is TLS-encrypted either way. True private
> connectivity (VPC Peering / Private Service Connect) requires the paid M10+
> tier (see the M0 note in step 1).

**One extra API.** Besides the APIs from step 2, this section needs the
**Compute Engine API** (`compute.googleapis.com`), because VPC networks, Cloud Router,
Cloud NAT and static IPs all belong to this API. Direct VPC Egress itself is covered
by the Cloud Run API. Enable it once:

```bash
gcloud services enable compute.googleapis.com --project "$GOOGLE_PROJECT_ID"
```

Or manually in the **GCP Console**: *APIs & Services → Library* → search
**Compute Engine API** → **Enable** (the console also offers an *Enable* button
when you first open *VPC network*).

**No firewall rules needed.** A fresh custom-mode VPC comes with exactly two
implied rules: *allow all egress* and *deny all ingress*. Everything here is
outbound, the container dials Atlas and OpenRouter, while
ingress (users, Cloud Run's health probes) arrives through Google's front end
and never touches the VPC. Even `mongodb+srv://` name resolution is unaffected.

### 1. VPC network + subnet

One small subnet in the service's region (direct VPC egress assigns one IP per
instance — size the range for your `--max-instances`):

```bash
gcloud compute networks create librechat-vpc \
  --subnet-mode=custom --project "$GOOGLE_PROJECT_ID"

gcloud compute networks subnets create librechat-egress \
  --network=librechat-vpc --region "$GOOGLE_REGION" --range=10.0.0.0/24 \
  --project "$GOOGLE_PROJECT_ID"
```

Or manually in the **GCP Console**: *VPC network → VPC networks → CREATE VPC
NETWORK* (custom mode) called `librechat-vpc-network`→ add one subnet named `librechat-egress` in
`GOOGLE_REGION` with an unused private range (e.g. `10.0.0.0/24`).

### 2. Static IP + Cloud NAT

```bash
# The single fixed egress IP — this is what Atlas will allow-list (step 4).
gcloud compute addresses create librechat-egress-ip \
  --region "$GOOGLE_REGION" --project "$GOOGLE_PROJECT_ID"

# Router, then NAT using only the reserved IP.
gcloud compute routers create librechat-router \
  --network=librechat-vpc --region "$GOOGLE_REGION" --project "$GOOGLE_PROJECT_ID"

gcloud compute routers nats create librechat-nat \
  --router=librechat-router --region "$GOOGLE_REGION" --project "$GOOGLE_PROJECT_ID" \
  --nat-external-ip-pool=librechat-egress-ip --nat-all-subnet-ip-ranges
```

Or manually in the **GCP Console**: *VPC network → IP addresses → RESERVE
EXTERNAL STATIC ADDRESS* — name `librechat-egress-ip`, IP version **IPv4**,
Network Service Tier **Premium** (the default), Type **Regional** (not Global),
Region `GOOGLE_REGION`, Source **None (Google external IP address pool)**,
Attached to **None** (the NAT claims it below; this address never attaches to a
VM — the list will later show *In use by Cloud NAT*). Then *Network
Connectivity → Cloud Router → CREATE ROUTER* — name `librechat-router`,
Network the network from step 1, Region `GOOGLE_REGION`; then on
that router *NAT → ADD NAT* — gateway name `librechat-nat`, NAT type
**Public**, *Cloud NAT IP addresses* → **Manual**, *IP address 1* =
`librechat-egress-ip`, source subnets at their default *All primary and
secondary IP ranges*, everything else at defaults.

### 3. Attach the VPC to the Cloud Run service

Atlas resolves to public IPs, so the egress mode must be **`all-traffic`** —
`private-ranges-only` would bypass the NAT for exactly the traffic you want to
control. The subnet must be in the service's region (`$GOOGLE_REGION`):

```bash
gcloud run services update librechat --project "$GOOGLE_PROJECT_ID" --region "$GOOGLE_REGION" \
  --network=librechat-vpc --subnet=librechat-egress --vpc-egress=all-traffic
```

Or manually in the **GCP Console**: *Cloud Run → Services → librechat →
Networking* tab → *Connect to a VPC for outbound traffic* → *Network* the VPC
from step 1, *Traffic routing* **Route all traffic to the VPC** → deploy the revision.

No `scripts/deploy.sh` change: the VPC attachment is a property of the service
and survives future `gcloud run deploy` runs (local or CI). Side effect: **all**
container egress, including the OpenRouter API calls, now flows through the
NAT; that works fine, it just no longer uses Google's default egress path.

### 4. Tighten the Atlas allow-list

In *Network Access → IP Access List*:

1. **Add IP Address**: the reserved IP (find it with
   `gcloud compute addresses describe librechat-egress-ip --region "$GOOGLE_REGION" --format='value(address)'`), and wait for it to turn **Active**.
2. **Delete** the `0.0.0.0/0` entry, if any.

If you later allocate a second static IP for NAT redundancy, add it to the
allow-list too.

### Costs & caveats

- **Direct VPC Egress itself has no hourly charge** What remains
  are Cloud NAT gateway and per-GiB processing fees and the static IP.
- The NAT becomes a dependency of every DB connection: if it or the VPC
  attachment is misconfigured, revisions fail the startup probe with the
  MongoDB connect error (the container exits before `/health` ever answers).
- A VPC in the **same project** needs no extra IAM beyond `roles/run.admin`; a
  **Shared VPC** (host project) additionally needs `compute.networkUser` for
  Cloud Run's service agent.

---

## Known Limitations

- **Ephemeral filesystem**: `uploads/`, `logs/` and similar local writes die
  with the instance. Conversations live in MongoDB Atlas, but uploaded files do
  not: configure an external `fileStrategy` (S3 and others) in `librechat.yaml`
  if users need durable file storage.
- **No database backups on the free tier**: Atlas M0 has no backups; deleting
  or corrupting the cluster loses all chat history. Export regularly or move to
  a paid Atlas tier if that matters.
- **First registered user becomes admin**: upstream LibreChat behavior. While
  `ALLOW_REGISTRATION=true`, anyone who reaches the URL can sign up, so the
  open → register → close steps in *First deployment* is a manual gate.
- **Config changes require a rebuild**: `librechat.yaml` is baked into the
  image, so any config or model change triggers the full Cloud Build
  (~20–25 minutes cold; `cloudbuild.yaml` configures no layer caching). Only
  secret and env-var changes are fast (new revision within seconds).
- **MongoDB Atlas is internet-reachable in the default setup**: the initial
  `0.0.0.0/0` allow-list (step 1.2) exposes the Atlas endpoint to the whole
  internet; TLS and strong passwords still apply. The
  [Hardening](#hardening-private-egress-to-mongodb-atlas) section shrinks this
  to one static IP, but only Atlas M10+ offers truly private connectivity.
- **Single region, extra egress dependency**: one Cloud Run service in one
  region; no multi-region failover. After *Hardening*, the Cloud NAT is an
  additional single point of failure for all outbound traffic (Atlas and
  OpenRouter).
- **Stop sequences are dropped on the OpenRouter endpoint**: `librechat.yaml`
  sets `dropParams: ["stop"]` because several models behind OpenRouter reject
  the `stop` parameter; prompts that rely on stop sequences won't get them.

---

## ⚖️ License & Commercial Usage

Copyright (c) 2026 thorsphere. All rights reserved.

This project is licensed under the **Functional Source License v1.1 (FSL-1.1-ALv2)**. 

* The use, modification, and redistribution of this Go package is completely free for private, educational, non-commercial, and internal purposes. 
* If you are a company or institution looking to use this package in a commercial product, service, or business environment, you must secure a commercial license.
* Each version of this software automatically converts to the fully open-source Apache License, Version 2.0 on the second anniversary of its release.

For full details, please see the [LICENSE](LICENSE.md) file.

### 💼 Commercial Licensing & Inquiries

To purchase a commercial license or discuss support options, please reach out directly:

* 📩 **Contact:** business at thorsphere dot com
* 💬 **Response Time:** Usually within a couple of business days.

*Please include your company name and a brief overview of your use case so I can provide the right licensing details.*
