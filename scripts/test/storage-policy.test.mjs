import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';

test('local private storage policy supports multipart reconciliation and scoped cleanup',async()=>{
 const source=await readFile(new URL('../../infrastructure/docker/storage-init.sh',import.meta.url),'utf8');
 const template=source.match(/printf '(\{"Version"[^'\n]+\})'/)?.[1];
 assert.ok(template,'Storage policy template must be reviewable');
 const bucket='generated-ci-bucket',policy=JSON.parse(template.replaceAll('%s',bucket));
 const objects=policy.Statement.find(s=>s.Resource[0]===`arn:aws:s3:::${bucket}/objects/*`);
 assert.ok(objects,'Application access must stay within private object prefix');
 for(const action of ['s3:PutObject','s3:GetObject','s3:GetObjectVersion','s3:DeleteObject','s3:DeleteObjectVersion','s3:ListMultipartUploadParts','s3:AbortMultipartUpload'])assert.ok(objects.Action.includes(action),action+' required for generated upload lifecycle');
 assert.deepEqual(new Set(objects.Action),new Set(['s3:PutObject','s3:GetObject','s3:GetObjectVersion','s3:DeleteObject','s3:DeleteObjectVersion','s3:ListMultipartUploadParts','s3:AbortMultipartUpload']));
 assert.deepEqual(policy.Statement.filter(s=>s!==objects),[{Effect:'Allow',Action:['s3:GetBucketVersioning'],Resource:[`arn:aws:s3:::${bucket}`]}]);
 assert.ok(policy.Statement.every(s=>s.Effect==='Allow'&&!('Principal' in s)));
 assert.ok(source.includes('mc anonymous set none "local/$S3_BUCKET"'));
});
