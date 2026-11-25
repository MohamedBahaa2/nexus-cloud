# TODO: split the S3 endpoint in file-service

## Problem

file-service uses one setting, `S3_ENDPOINT`, for two jobs:

- **Its own calls** (list, delete, readiness) are made from inside the container, so they need `http://s3:8333`.
- **Presigned URLs** are opened by the browser, so they need `http://localhost:9000`.

No single value works for both when file-service runs in a container. See the "Open issue" in [stage-1-docker.md](stage-1-docker.md#networking-two-names-for-the-same-thing).

## Fix

Use two S3 clients: one for the service's own calls, and one that only signs browser URLs. This is the same idea as `KEYCLOAK_INTERNAL_URL` and `LIVEKIT_API_URL`.

1. **`services/file-service/src/config/env.ts`**: add an optional `S3_PUBLIC_ENDPOINT` (a URL, or empty meaning not set), defined the same way as `KEYCLOAK_INTERNAL_URL`.
2. **`services/file-service/src/storage/storage.service.ts`** (client created around line 37):
   - Keep the existing client on `S3_ENDPOINT` for the service's own calls.
   - Add a second client with the same settings (region, credentials, path style), but whose endpoint is `S3_PUBLIC_ENDPOINT` when set, falling back to `S3_ENDPOINT`.
3. **Same file, the two `getSignedUrl` calls** (around lines 71 and 79): pass the second client. Signing runs locally with no network call, so the container never needs to reach the public address.
4. **`deploy/docker-run/file-service.env`**:
   ```
   S3_ENDPOINT=http://s3:8333
   S3_PUBLIC_ENDPOINT=http://localhost:9000
   ```
5. **Docs**: add `S3_PUBLIC_ENDPOINT` to `services/file-service/.env.example` and to the configuration table in [deployment-notes.md](deployment-notes.md). Note that it stays unset on AWS, where real S3 is reachable from both sides. Then mark the open issue in `stage-1-docker.md` as resolved.

Local development (`npm run dev`) is unaffected: with the variable unset, both clients use the same endpoint.

## Check

- `curl localhost:3001/ready`: the S3 check is OK.
- In the browser at http://localhost:5173, upload a file and download it again.
- Run the file-service tests (`npm test -w @nexusdrive/file-service`).
