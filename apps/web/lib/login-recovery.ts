const destinations=new Set(['/dashboard','/photos','/videos','/account','/account/delete','/sessions','/devices','/billing','/billing/success','/billing/cancel','/billing/history']);
export function loginDestination(value:string|null){return value&&destinations.has(value)?value:'/dashboard';}
export function loginRecoveryFields(status:number,mode:string){return mode==='login'&&status===409;}
export function browserDeviceIdentifier(storage:Pick<Storage,'getItem'|'setItem'>,create=()=>crypto.randomUUID()){
 const prior=storage.getItem('backup_device_id');
 if(prior&&/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i.test(prior))return prior;
 const id=create();storage.setItem('backup_device_id',id);return id;
}
