# Olympus applications

Add each application in its own directory and list that directory in
`kustomization.yaml`. Existing workloads are not adopted automatically.

Before importing an application:

1. Remove server-generated fields from exported manifests.
2. Replace plaintext secrets with SOPS-encrypted secrets.
3. Pin image versions or digests.
4. Render with `kubectl kustomize .\apps\olympus`.
5. Review the diff before committing and pushing.

