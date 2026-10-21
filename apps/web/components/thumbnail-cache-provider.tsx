'use client';
import {createContext,useContext,useEffect,useMemo,type ReactNode} from 'react';
import {LibrarySnapshots} from '../lib/library-snapshot';
import {ThumbnailCache} from '../lib/thumbnail-cache';
const LibraryContext=createContext<LibrarySnapshots|null>(null);
const Context=createContext<ThumbnailCache|null>(null);
export function ThumbnailCacheProvider({account,children}:{account:string;children:ReactNode}){
 const scope=useMemo(()=>({cache:new ThumbnailCache(),library:new LibrarySnapshots(),leases:0}),[account]);
 useEffect(()=>{scope.leases++;return()=>{scope.leases--;queueMicrotask(()=>{if(scope.leases===0){scope.cache.clear();scope.library.clear()}})}},[scope]);
 return <LibraryContext.Provider value={scope.library}><Context.Provider value={scope.cache}>{children}</Context.Provider></LibraryContext.Provider>;
}
export const useThumbnailCache=()=>useContext(Context);

export const useLibrarySnapshots=()=>useContext(LibraryContext);
