# Engineering rules

Scope: the entire repository. ACL-003 local photo-library discovery is authorized by its specification; do not start ACL-004 without a specification.
Use neutral internal domain names. Keep Acloud branding in configuration and display copy.

1. Customer data protection and prevention of data loss take priority over feature velocity.
2. Never mark a media asset as PROTECTED until server-side verification confirms that the object exists and passes the required integrity checks.
3. Never automatically delete an original photo or video from a user's device.
4. Storage objects must never be publicly accessible.
5. Permanent object URLs must not be exposed.
6. Storage credentials must never be embedded in the iOS application.
7. All upload authorizations must be short-lived and scoped to the authenticated user and intended object.
8. Storage quotas must be enforced server-side.
9. Payment status must never be trusted from a client application.
10. Future payment entitlement changes must originate from verified server-side payment events.
11. Payment webhook processing must be idempotent.
12. Failed subscriptions must never result in immediate customer-data deletion.
13. Secrets, API keys and credentials must never be committed to Git.
14. Security-sensitive functionality requires automated tests.
15. Database migrations must be version controlled.
16. Destructive database migrations require explicit documentation and a recovery strategy.
17. The iOS application must contain no payment implementation unless explicitly introduced by a later approved specification.
18. Design uploads for unreliable networks, interrupted connections and expensive mobile data.
19. Preserve original media quality and relevant metadata wherever technically possible.
20. Every destructive customer-data operation must require explicit authorization and must be auditable.
21. Logging must never expose customer photos, authentication credentials, encryption keys or other sensitive content.
22. Production and development environments must remain logically separated.

Run applicable tests and builds. Record unavailable checks honestly. Never push without explicit user instruction.

ACL-003: never upload media, modify/delete Photos assets, infer protection, or log
local asset identifiers, filenames, paths, contents, thumbnails or EXIF. Use only
public metadata APIs, respect limited access and keep discovery local. Library
removal/access loss must never authorize deletion of a future server backup.
