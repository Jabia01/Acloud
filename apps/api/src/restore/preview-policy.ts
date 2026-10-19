import {ConflictException} from '@nestjs/common';
export const previewMaximumBytes=32*1024*1024;
export type PreviewResource={kind:string;protection_state:string;source_changed:boolean;integrity_degraded:boolean;review_required:boolean;role:string;expected_size:string|number;expected_sha256:string};
// This grants bounded preview bytes, never a Photos reconstruction or fidelity acceptance.
export function requirePreviewResource(asset:{media_type:string;verified_size_bytes:string|number;expected_checksum:string},resources:PreviewResource[],maximumBytes=previewMaximumBytes){
 const size=Number(asset.verified_size_bytes);
 if(!['image','video'].includes(asset.media_type)||!Number.isSafeInteger(size)||size<1||size>maximumBytes)throw new ConflictException('Preview type or size unavailable');
 for(const r of resources){
  if(!['ORDINARY','LEGACY_SINGLE','LIVE_PHOTO','EDITED'].includes(r.kind)||r.protection_state!=='FULLY_PROTECTED'||r.source_changed||r.integrity_degraded||r.review_required)throw new ConflictException('Complete current preservation required');
  if(!['PRIMARY_STILL','PRIMARY_VIDEO','EDITED_RENDER'].includes(r.role)||Number(r.expected_size)!==size||r.expected_sha256!==asset.expected_checksum)throw new ConflictException('Verified display resource required');
 }
}
