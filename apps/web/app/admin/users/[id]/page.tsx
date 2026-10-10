import {AdminShell} from '../../../../components/admin-shell';
export default async function Page({params}:{params:Promise<{id:string}>}){return <AdminShell section="user" id={(await params).id}/>;}
