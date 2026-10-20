import {ForbiddenException,ServiceUnavailableException} from '@nestjs/common';
import type {PoolClient} from 'pg';
import type {Principal} from '../auth/auth.service';
import {ownerTestConfiguration,ownerTestConfigured,OWNER_TEST_FILE_BYTES} from '../beta/owner-test';
import {betaConfiguration} from '../beta/config';
import type {BetaPolicy} from '../beta/policy';
// Small derivatives never grant original-download or Photos reconstruction access.
export async function thumbnailAccess(c:PoolClient,p:Principal,id:string,write:boolean,beta:BetaPolicy){
 if(process.env.THUMBNAILS_ENABLED!==undefined&&!['true','false'].includes(process.env.THUMBNAILS_ENABLED))throw new ForbiddenException('Thumbnail access unavailable');
 if(process.env.THUMBNAILS_ENABLED==='false')throw new ServiceUnavailableException('Thumbnails paused');
 if(ownerTestConfigured()){
  const cfg=ownerTestConfiguration()!,now=Date.now();
  if(now<cfg.start||now>=cfg.end||p.userId!==cfg.account||!p.deviceId)throw new ForbiddenException('Private thumbnail access unavailable');
  // The source device may publish. A same-account live web session may only read.
  const session=(await c.query(`SELECT s.id FROM sessions s JOIN users u ON u.id=s.user_id JOIN devices d ON d.id=s.device_id AND d.user_id=u.id
   WHERE s.id=$1 AND s.user_id=$2 AND s.device_id=$3 AND s.revoked_at IS NULL AND s.expires_at>now()
   AND d.revoked_at IS NULL AND u.status='ACTIVE' AND u.privacy_state='ACTIVE' AND u.email_verified_at IS NOT NULL AND u.abuse_review=false
   AND (d.id=$4 OR ($5=false AND d.platform='web'))`,[p.sessionId,cfg.account,p.deviceId,cfg.device,write])).rows[0];
  if(!session)throw new ForbiddenException('Private thumbnail access unavailable');
  const asset=(await c.query(`SELECT a.id FROM assets a JOIN upload_sessions s ON s.asset_id=a.id AND s.user_id=a.user_id
   WHERE a.id=$1 AND a.user_id=$2 AND a.device_id=$3 AND a.created_at >= $4 AND a.created_at < $5
   AND a.storage_provider='backblaze_b2' AND a.privacy_deleted_at IS NULL AND a.expected_size_bytes BETWEEN 1 AND $6`,[id,cfg.account,cfg.device,new Date(cfg.start),new Date(cfg.end),OWNER_TEST_FILE_BYTES])).rows[0];
  if(!asset)throw new ForbiddenException('Private thumbnail access unavailable');
  return;
 }
 const cfg=betaConfiguration();
 if(process.env.NODE_ENV==='production'){
  if(!cfg.enabled)throw new ForbiddenException('Thumbnail acceptance pending');
  await beta.assertEnvironment(c);await beta.active(p.userId,c);await beta.requireAdmission('REAL_MEDIA',c);
 }
 if(write){
  const source=(await c.query('SELECT id FROM assets WHERE id=$1 AND user_id=$2 AND device_id=$3 AND privacy_deleted_at IS NULL',[id,p.userId,p.deviceId])).rows[0];
  if(!p.deviceId||!source)throw new ForbiddenException('Source device required');
 }
}
