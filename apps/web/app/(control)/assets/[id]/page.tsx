import {ControlPlane} from '../../../../components/control-plane';
export default async function Page({params}:{params:Promise<{id:string}>}) { const {id}=await params; return <ControlPlane view="asset" id={id}/>; }
