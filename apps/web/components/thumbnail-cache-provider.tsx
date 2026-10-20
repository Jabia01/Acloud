'use client';
import {createContext,useContext,useEffect,useMemo,type ReactNode} from 'react';
import {ThumbnailCache} from '../lib/thumbnail-cache';
const Context=createContext<ThumbnailCache|null>(null);
export function ThumbnailCacheProvider({account,children}:{account:string;children:ReactNode}){
 const scope=useMemo(()=>({cache:new ThumbnailCache(),leases:0}),[account]);
 useEffect(()=>{scope.leases++;return()=>{scope.leases--;queueMicrotask(()=>{if(scope.leases===0)scope.cache.clear()})}},[scope]);
 return <Context.Provider value={scope.cache}>{children}</Context.Provider>;
}
export const useThumbnailCache=()=>useContext(Context);
