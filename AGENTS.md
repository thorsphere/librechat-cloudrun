# Engineering & AI Collaboration Guidelines

This repository is developed using AI-assisted engineering with strict human oversight. A high bar for stability, and code hardening is maintained.

---

## 🎯 Architecture & Intent
- **Context:** State-free LibreChat deployment on GCP Cloud Run with MongoDB
  Atlas (external database) and OpenRouter as the model provider. All state
  lives in Atlas; Cloud Run instances are disposable.
- **Layout:** `Dockerfile` (multi-stage image build) · `librechat.yaml`
  (LibreChat config, baked into the image) · `cloudbuild.yaml` (image build
  spec) · `scripts/gcp-setup.sh` (optional one-time GCP setup) ·
  `scripts/deploy.sh` (build + deploy) · `.github/workflows/deploy.yml`
  (CI/CD) · `README.md` (canonical setup & ops guide — link to it, do not
  duplicate it here).
- **Frameworks:** Bash + Docker build tooling only. This is NOT a Node
  project despite building one, no `package.json`, no `npm install` here.
  LibreChat source is cloned at build time from `LibreChat-AI/LibreChat` at a
  pinned tag; no application code is vendored. GCP surface: Cloud Run, Cloud
  Build, Artifact Registry, Secret Manager; GitHub Actions authenticates via
  Workload Identity Federation (no service-account keys).
- **Configuration:** Secrets live only in Secret Manager and are attached as
  env vars at deploy time; `librechat.yaml` must stay secret-free and use
  `${ENV_VAR}` interpolation. Secret names and env names are fixed contracts
  shared by `gcp-setup.sh`, `deploy.sh`, and the README (see §2).

---

## 🤖 AI Agent Instructions
When generating code, refactoring, or planning tasks, you MUST adhere to these technical constraints:

### 1. Coding Style (match the existing codebase exactly)
- **File header:** Every source file starts with the thorsphere copyright
  notice (FSL-1.1-ALv2, see any existing file) followed by the package clause.
- **Atomic lines:** Comment every code line that carries behavior of its
  own (a call, assignment, branch, or return). Scaffolding lines (braces,
  bare closures) may go without; const-block members each carry their own
  trailing comment.
- **Naming prefixes:** identifiers in shared, project-scoped namespaces
  (Secret Manager, IAM) carry an owning-service prefix (`librechat-` for the
  app's secrets, `github-actions-` for the CI deployer). Names scoped to a
  single container or repo stay unprefixed; GCP tooling env vars use
  `GOOGLE_` (the full conventions are listed in §2). Apply the same pattern
  to any new resource.

---

### 2. Deliberate Design Decisions — do NOT "fix" these
- **`HOST=0.0.0.0` in the Dockerfile:** LibreChat defaults to `localhost`,
  which breaks Cloud Run health checks. Not a security issue — Cloud Run
  fronts all ingress.
- **Pinned versions move in pairs:** `ARG LIBRECHAT_VERSION` (Dockerfile) and
  `version:` (librechat.yaml, the config schema version) must always match the
  same LibreChat release. `node:24-alpine` tracks upstream LibreChat's own
  Dockerfile — bump it only when upstream does.
- **`GOOGLE_` env prefix convention:** GCP-related env vars are `GOOGLE_*`
  (`GOOGLE_PROJECT_ID`, `GOOGLE_REGION`, ...) — never `GCP_*`. The deployer
  service-account id is `github-actions-deployer`. The WIF provider and SA go
  in GitHub repo *variables*, not secrets (identifiers, not credentials; the
  trust boundary is the WIF attribute condition pinning the repo).
- **Secret names are a three-file contract:** `librechat-mongo-uri`,
  `librechat-openrouter-api-key`, `librechat-creds-key`, `librechat-creds-iv`,
  `librechat-jwt-secret`, `librechat-jwt-refresh-secret` (Secret Manager,
  `librechat-` prefix = names are project-scoped) map 1:1 to
  `MONGO_URI`, `OPENROUTER_API_KEY`, `CREDS_KEY`, `CREDS_IV`,
  `JWT_SECRET`, `JWT_REFRESH_SECRET` (env vars, fixed by LibreChat) across
  `gcp-setup.sh`, `deploy.sh`, and the README. Rename = edit all three.
- **Config is baked, not mounted:** `librechat.yaml` is `COPY`-ed into the
  image and config changes require a rebuild. Cloud Run has no volume mounts;
  immutable revisions are the point.
- **Exec-form `CMD ["node", "api/server/index.js"]`:** no npm wrapper, so
  Cloud Run's SIGTERM reaches node directly for graceful shutdown.
- **Shallow `.git` is kept in the build stage:** LibreChat resolves its
  version for Settings → About from it.
- **`dropParams: ["stop"]` on the OpenRouter endpoint:** several models behind
  OpenRouter reject the `stop` parameter.
- **Ephemeral filesystem is accepted:** `uploads/`, `logs/` die with the
  instance; durable files need an external `fileStrategy`. Do not add local
  persistence workarounds.
- **"First registered user becomes admin"** is upstream LibreChat behavior —
  not a misconfiguration.

### 3. Build & Validation
This is a deployment-config repository. There is no application code and no
test suite. Validate changes locally with:

```bash
bash -n scripts/gcp-setup.sh scripts/deploy.sh   # shell syntax
docker build --check .                           # Dockerfile lint (BuildKit)
```

- Never run `scripts/gcp-setup.sh` or `scripts/deploy.sh` as "validation" —
  they mutate real GCP infrastructure.
- CI deploys only when the workflow's path filter matches (`Dockerfile`,
  `librechat.yaml`, `cloudbuild.yaml`, `scripts/**`, the workflow file).
  Doc-only changes never trigger a deploy.

---

## 🛠️ Human Review & Hardening Process
*Every line of code generated by AI agents undergoes a mandatory human review, hardening loop, and optimization pass before being submitted to the repository. The review loop applies to the internal AI-assisted process; external contribution policy is governed by CONTRIBUTING.md*
