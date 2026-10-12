# Acloud private beta privacy notice — DRAFT, not published

Last prepared: 12 October 2026. **Do not publish until the unresolved operator, contact, retention and provider fields below are completed and reviewed.** This describes the intended private staging scope, not an open customer launch.

## Who operates Acloud

Acloud is operated by **[LEGAL PERSON OR COMPANY — TO BE CONFIRMED]**. Contact **[WORKING PRIVACY EMAIL — TO BE CONFIRMED]** about your information, access or deletion requests. This notice will be available at **[FINAL NOTICE URL — TO BE CONFIRMED]**.

## Information we handle

When you create or use an account, we handle your email address, authentication information, account identifier and session/security records. We retain password verifiers rather than intentionally storing raw passwords. The app stores session credentials in the device Keychain and uses app-generated device/library identifiers to associate transfers with your account.

With your Photos permission, the app can review metadata for the library items you allow. Discovery stays on the device and does not automatically upload your library. When you explicitly select media for an enabled backup workflow, the selected original bytes and associated preservation information are sent to private cloud storage. This can include photos, videos, video sound, dates, dimensions, resource types, integrity hashes and embedded metadata such as GPS coordinates. We preserve originals rather than promise to remove their embedded metadata. Photos may contain information about you or other people, including sensitive information.

We keep transfer/verification status, storage usage and security evidence to operate backup and restore. Server reliability records can include bounded event codes, retries, request/restore timing and account-associated security/audit events. The app checks free device space locally before downloading a restore and can pause when space is insufficient; it does not send the capacity reading as telemetry.

## Why we use it

We use this information to authenticate accounts, associate devices, protect access, enforce storage limits, back up and restore selected media, verify integrity, deliver transactional messages and investigate operational failures. The reviewed native client has no advertising or tracking SDK and does not use backup content for advertising or content profiling. We do not operate a public sharing feature in this beta.

The current native app does not capture photos with the camera or record from the microphone. Sound and location information may already exist in media you choose to back up. iCloud-only originals require the app's explicit download setting and network conditions; retrieving or restoring Photos items may also involve your Apple/iCloud account under Apple's practices.

## Providers and storage

Staging uses Railway for API/worker hosting, Supabase for the database, Backblaze B2 for private media objects, Resend for transactional email and Vercel for the web interface. Each receives information needed for its service, subject to the actual account configuration and contracts. **[CONFIRM PROVIDER LOCATIONS, BACKUPS/LOGS, CONTRACTS AND CROSS-BORDER ARRANGEMENTS BEFORE PUBLICATION.]**

Transfers use protected network connections, and media access is controlled through the authenticated service and scoped temporary authorizations. This is not a claim that only you hold decryption keys or that server operators are technically unable to access content. **[CONFIRM AND DESCRIBE ACTUAL PRIVILEGED ACCESS AND SUPPORT PROCESS.]**

## Retention and deletion

**[INSERT APPROVED RETENTION PERIODS AND HOW THEY APPLY TO ACTIVE ACCOUNTS, CLOSED ACCOUNTS, MEDIA VERSIONS, PENDING TRANSFERS, LOGS, AUTH RECORDS AND INFRASTRUCTURE BACKUPS.]** Access restriction, account closure, cloud-object deletion and expiry of retained infrastructure backups are different actions. We do not promise immediate removal of every copy.

Deleting an account or backup must not automatically delete originals from your device Photos library. Customer Free Up Space is disabled in this beta. Keep your originals and another independent copy while testing. Failed payments or beta suspension do not by themselves authorize immediate deletion of customer content.

## Your choices and requests

You can control Photos access in device Settings, select which items enter an enabled backup workflow and stop or pause transfers using the app's controls. You can contact the privacy address above to request help with access, corrections, export or account deletion. **[CONFIRM REQUEST VERIFICATION, AVAILABLE SELF-SERVICE FLOWS, APPLICABLE RIGHTS AND RESPONSE PROCESS BEFORE PUBLICATION.]** Some export/deletion features are gated or not yet accepted for the hosted beta; do not rely on a draft feature as a promise of immediate completion.

## Beta audience and updates

**[CONFIRM INITIAL AUDIENCE, AGE REQUIREMENTS AND JURISDICTIONS.]** Media preservation and recovery have beta limitations; not every media type or failure scenario has been accepted. We will identify material changes to the notice before asking beta users to accept the applicable version. **[CONFIRM NOTICE VERSIONING AND NOTIFICATION PROCESS.]**
