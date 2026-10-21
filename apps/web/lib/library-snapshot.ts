import type {Inventory} from './control';
export class LibrarySnapshots{
 private pages=new Map<string,{inventory:Inventory;updated:number}>();
 get(key:string,now=Date.now()){const value=this.pages.get(key);if(!value)return null;if(now-value.updated>30*60*1000){this.pages.delete(key);return null}return value;}
 set(key:string,inventory:Inventory,updated=Date.now()){
  if(!['photos:','videos:'].includes(key)||inventory.items.length>300)return;
  this.pages.set(key,{inventory,updated});
 }
 clear(){this.pages.clear()}
}
