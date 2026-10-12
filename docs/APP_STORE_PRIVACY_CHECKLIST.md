# App Store / TestFlight privacy preparation

Updated 12 October 2026. Native engineering preparation is recorded in [IOS_PRIVACY_REVIEW.md](IOS_PRIVACY_REVIEW.md); user-facing draft text is [BETA_PRIVACY_NOTICE_DRAFT.md](BETA_PRIVACY_NOTICE_DRAFT.md). Neither is a submitted Apple questionnaire or a published approved notice.

| Topic | Current evidence | Remaining step |
| --- | --- | --- |
| Photos/media | Native original connector exists. Hosted ordinary iPad photo/video backup and restore passed in Debug. Explicit selection; originals retained. | Release admission and broader media/device cases; hosted interruption test pending by user choice. |
| Accounts/identifiers | Email, account/device/library/session bindings and security records mapped. | Confirm exact final service/provider disclosures. |
| Embedded content | Original video sound and possible GPS metadata covered conservatively by Audio Data and Precise Location declarations. No microphone or live-location permission. | Final reviewer classification against released functionality. |
| Diagnostics | Account-linked restore codes/timings and server reliability evidence mapped; no native crash/analytics SDK. | Final hosting and Apple TestFlight diagnostics/feedback inventory. |
| Tracking | Reviewed native inventory has no ads/tracking SDK; manifest tracking false, tracking domains empty. | Recheck dependencies/endpoints in final artifact. |
| Required-reason APIs | App-only UserDefaults CA92.1; local restore capacity E174.1. Manifest included as app resource. | Recheck final archive/API inventory after future changes. |
| Data collection manifest | Nine app-functionality categories declared as linked and not tracking; source rationale documented. | Final operator/provider review and Apple privacy report. |
| Payments | No native payment implementation; staged payments remain gated. | Revisit declarations if enabled later. |
| Privacy notice | Concrete draft prepared with unresolved fields visibly marked. | Operator/legal identity, contact, notice URL, retention and provider/transfer review. |
| Deletion/export | Engineering lifecycle exists, but hosted gated behavior and retention are not an immediate-deletion promise. | Accepted procedures, support handling and approved retained-copy periods. |
| Distribution | Paid membership absent; no upload or privacy answers submitted. | Membership, owned identity/signing, final archive validation and TestFlight acceptance. |

Follow [Apple app privacy details](https://developer.apple.com/app-store/app-privacy-details/). Verify the actual signed Release artifact and full service inventory before answering the portal. Do not copy placeholders into a public notice or mark legal/retention acceptance complete from a build.
