import {ConflictException,ServiceUnavailableException} from '@nestjs/common';
import {SafeErrors} from '../src/auth/safe-errors';
function rendered(error:Error){let body:unknown;const response:any={setHeader:()=>{},status:()=>response,json:(value:unknown)=>{body=value}};new SafeErrors().catch(error,{switchToHttp:()=>({getResponse:()=>response})} as any);return body;}
test('cloud quota exposes only bounded capacity fields and never arbitrary error details',()=>{
 expect(rendered(new ConflictException({message:'Cloud storage full',code:'CLOUD_QUOTA_EXCEEDED',requiredBytes:100,availableBytes:20,privateKey:'PRIVATE'}))).toEqual({message:'Cloud storage full',code:'CLOUD_QUOTA_EXCEEDED',requiredBytes:100,availableBytes:20});
 expect(rendered(new ConflictException({message:'Conflict',code:'PRIVATE_CODE',requiredBytes:100}))).toEqual({message:'Conflict'});
 expect(rendered(new ServiceUnavailableException('private details'))).toEqual({message:'Service unavailable'});
 expect(rendered(new ConflictException({message:'Full',code:'CLOUD_QUOTA_EXCEEDED',requiredBytes:Infinity,availableBytes:-1}))).toEqual({message:'Full',code:'CLOUD_QUOTA_EXCEEDED'});
});
