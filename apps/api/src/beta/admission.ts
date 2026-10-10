import {createHash} from 'node:crypto';
import {mandatoryGates} from './config';
export const admissionGates={
 RESTORE:[...mandatoryGates,'B2','NATIVE_CONNECTOR','APPLE_DEVICE','SECURE_DOWNLOAD','PHOTOKIT_RESTORE'],
 REAL_MEDIA:[...mandatoryGates,'B2','NATIVE_CONNECTOR','IPHONE','DISTRIBUTION'],
 PAYMENTS:[...mandatoryGates,'PAYSTACK','APPROVED_PRICES','BILLING_REVIEW','WEBHOOK','BILLING_WORKER','PAYMENT_SUPPORT'],
 FREE_UP_SPACE:[...mandatoryGates,'B2','NATIVE_CONNECTOR','IPHONE','DISTRIBUTION','COMPLETE_MANIFEST','DESTRUCTIVE_IPHONE','ICLOUD_REVIEW','CLEANUP_LEGAL','RESTORE','CLEANUP_RECONCILIATION']
} as const;
export type Admission=keyof typeof admissionGates;
export function admissionDecision(kind:Admission,rows:{gate:string;status:string;evidence_id:string;approved_by:string}[],bound:boolean){const relevant=rows.filter(r=>(admissionGates[kind] as readonly string[]).includes(r.gate)).sort((a,b)=>a.gate.localeCompare(b.gate));const accepted=bound&&admissionGates[kind].every(g=>relevant.filter(r=>r.gate===g).length===1&&relevant.some(r=>r.gate===g&&r.status==='PASS'&&r.evidence_id&&r.approved_by));return{accepted,digest:createHash('sha256').update(JSON.stringify([kind,bound,relevant])).digest('hex')};}
