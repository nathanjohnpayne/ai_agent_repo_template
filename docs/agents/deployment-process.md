# Deployment Process

See `DEPLOYMENT.md` for all build and deployment steps.

If the project uses Firebase or Google Cloud, prefer the canonical
`scripts/gcloud/gcloud`, `scripts/firebase/op-firebase-setup`, and
`scripts/firebase/op-firebase-deploy` flow:

- The canonical source-credential precedence — interactive and CI — is documented in `DEPLOYMENT.md` § [Deploy credential precedence (canonical)](../../DEPLOYMENT.md#deploy-credential-precedence-canonical). The default day-to-day credential is the per-project Firebase-vault SA key (`op://Firebase/{project-id} — Firebase Deployer SA Key`); the shared 1Password ADC remains a fallback.
- The 1Password-first deploy-auth model is a deliberate default. Do not switch template-derived repos back to routine browser-login, `firebase login`, or unmanaged on-disk deploy-key auth without explicit human approval.
- When the resolved source credential is the project SA key directly, no impersonation wrapper is used (faster, no `serviceAccountTokenCreator` IAM dependency). When it's the shared ADC or another non-matching credential, `op-firebase-deploy` writes a temporary `impersonated_service_account` credential and stamps the target project as the quota project.
- Do not introduce long-lived service account keys into repo docs,
  scripts, or secret stores unless a project explicitly requires them. The Firebase-vault SA key in 1Password is the supported on-account form; on-disk deploy keys are not.
- If credential preflight was run at session start (`scripts/op-preflight.sh --mode all`),
  deploy credentials are already cached. No additional biometric prompt is needed for deployment.
- If an `op` command fails with a sign-in or biometric error during deploy, follow the pause-and-prompt procedure in [operating-rules.md](operating-rules.md#1password-cli-authentication-failures). Do not retry or work around the failure without the human present.
