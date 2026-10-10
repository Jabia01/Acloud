import { Inject, Injectable, ForbiddenException } from '@nestjs/common';
import { randomUUID } from 'node:crypto';
import { DatabaseService } from '../database.service';
import { lifecyclePolicy, sha } from './policy';
@Injectable()
export class LifecycleRetentionService {
    constructor(
    @Inject(DatabaseService)
    private db: DatabaseService) { }
    async run(apply = false) {
        const policy = lifecyclePolicy();
        if (apply && !policy.retention)
            throw new ForbiddenException('Retention execution disabled');
        return this.db.transaction(async (c) => {
            const policies = (await c.query('SELECT * FROM retention_policies ORDER BY category')).rows, id = randomUUID(), digest = sha(JSON.stringify(policies));
            // Only temporary export artifacts have an approved deletion implementation.
            // Financial, security, audit, media and deletion evidence are retained pending review.
            const candidates = (await c.query("SELECT e.id,e.user_id FROM privacy_export_jobs e JOIN retention_policies p ON p.category='privacy_exports' WHERE e.expires_at<=now() AND e.state<>'EXPIRED' AND p.enabled AND p.legal_approval='APPROVED' AND p.retention_class='DELETE' AND NOT EXISTS(SELECT 1 FROM data_holds h WHERE h.user_id=e.user_id AND h.released_at IS NULL) ORDER BY e.expires_at,e.id LIMIT $1", [policy.batch])).rows;
            await c.query("INSERT INTO retention_runs(id,mode,state,policy_digest,candidates,summary) VALUES($1,$2,'PLANNED',$3,$4,$5)", [id, apply ? 'APPLY' : 'DRY_RUN', digest, candidates.length, JSON.stringify({ category: 'privacy_exports', bounded: true, mediaDeletion: false })]);
            let processed = 0;
            if (apply)
                for (const e of candidates) {
                    await c.query('SELECT id FROM users WHERE id=$1 FOR UPDATE', [e.user_id]);
                    const current = (await c.query("SELECT id FROM privacy_export_jobs WHERE id=$1 AND user_id=$2 AND expires_at<=now() AND state<>'EXPIRED' FOR UPDATE", [e.id, e.user_id])).rows[0];
                    if (!current)
                        continue;
                    if ((await c.query('SELECT id FROM data_holds WHERE user_id=$1 AND released_at IS NULL LIMIT 1', [e.user_id])).rowCount)
                        continue;
                    await c.query('DELETE FROM privacy_export_chunks WHERE export_id=$1', [e.id]);
                    await c.query("UPDATE privacy_export_jobs SET state='EXPIRED',manifest=NULL WHERE id=$1", [e.id]);
                    await c.query("UPDATE privacy_exports SET state='EXPIRED',payload=NULL WHERE id=$1", [e.id]);
                    processed++;
                }
            await c.query("UPDATE retention_runs SET state='COMPLETE',processed=$2,finished_at=now() WHERE id=$1", [id, processed]);
            return { runId: id, dryRun: !apply, candidates: candidates.length, processed, policyDigest: digest, mediaDeletion: false };
        });
    }
}
