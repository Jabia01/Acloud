# Owner Live Photo / edited-photo backup test

Purpose: test capture and verified cloud preservation on the existing approved owner/device staging window. This is backup-only experimental testing, not proof of restoration fidelity or general beta acceptance.

## Availability

- Debug builds only, with `DevelopmentComplexMediaBackup=true` in the generated Debug app plist.
- The current signed-in device must receive a successful owner-test status response from the server. Existing account/device/window authorization and live upload switches remain mandatory.
- Beta Release uses its separate fail-closed plist and excludes this selection path at compile time. No backend flags, acceptance evidence or quotas are changed by this feature.

## Test

Start with one disposable Live Photo or edited photo in Backup → Choose photos and videos. Keep the original and avoid further edits during the transfer. Complete known resource sets route through the existing preservation planner, file preparer and multipart API. Live Photo pairs require the still and paired video; edited photos require original/rendered/adjustment resources. Supporting resources each count toward the existing 100-attempt/1 GiB window and 32 MiB per-resource cap. Unknown/incomplete/RAW resource sets and edited videos remain excluded.

Review **Backup completeness**, which shows required files verified. Individual transferred resources do not establish full protection of the asset. Existing changed-source checks, streaming checksums, exact storage/version verification and iCloud-original opt-in policy remain active. Reselecting an unchanged manifest reuses its recorded resources rather than creating a duplicate test set. Failed resources require the existing retry/recovery actions.

## Limits

Complex Photos restore remains separately gated. This test does not enable Live Photo reconstruction/playback, edited original/rendered restoration or editable-history reconstruction. No destructive cleanup, deletion, broad admission or release background-transfer setting is enabled. Keep originals until independent restore/fidelity acceptance is complete.

## Evidence

2026-10-16: six selection-policy tests plus six existing multi-resource preparation/account/isolation/change/iCloud tests passed (12 total). Signed Debug and unsigned Release builds passed. Built Debug plist confirms test switch true and cleanup false; Release background-transfer flag remains false. Physical successful resource capture/cloud completeness remains awaiting owner testing. No live customer media selected or uploaded by the agent, and no beta acceptance rows forged.
