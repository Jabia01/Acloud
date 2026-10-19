import {BadRequestException} from '@nestjs/common';
export const thumbnailMaximumBytes=40*1024,thumbnailAccountBudget=32*1024*1024;
export function thumbnailInput(value:unknown){
 if(!value||typeof value!=='object'||Array.isArray(value))throw new BadRequestException('Thumbnail required');
 const v=value as Record<string,unknown>;
 if(Object.keys(v).sort().join(',')!=='cloudVersionId,dataBase64,sourceSha256'||typeof v.cloudVersionId!=='string'||!/^[a-f0-9]{64}$/.test(v.cloudVersionId)||typeof v.sourceSha256!=='string'||!/^[a-f0-9]{64}$/.test(v.sourceSha256)||typeof v.dataBase64!=='string'||v.dataBase64.length>Math.ceil(thumbnailMaximumBytes/3)*4||!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(v.dataBase64))throw new BadRequestException('Invalid thumbnail');
 const bytes=Buffer.from(v.dataBase64,'base64');if(bytes.toString('base64')!==v.dataBase64)throw new BadRequestException('Invalid thumbnail');
 const dimensions=jpegDimensions(bytes);return{version:v.cloudVersionId,source:v.sourceSha256,bytes,...dimensions};
}
export function jpegDimensions(b:Buffer){
 const fail=()=>{throw new BadRequestException('Small metadata-free JPEG required');};
 if(b.length<4||b.length>thumbnailMaximumBytes||b.readUInt16BE(0)!==0xffd8||b.readUInt16BE(b.length-2)!==0xffd9)fail();
 let offset=2,width=0,height=0;
 while(offset+4<=b.length){
  if(b[offset++]!==0xff)fail();while(b[offset]===0xff)offset++;
  const marker=b[offset++];if(marker===undefined||offset+2>b.length)return fail();if(marker===0xda){if(!width)fail();return{width,height};}
  if(marker===0xe1||marker===0xed||marker===0xfe)fail(); // EXIF/XMP/IPTC/comments are unnecessary for display.
  const length=b.readUInt16BE(offset);if(length<2||offset+length>b.length)fail();
  if([0xc0,0xc1,0xc2].includes(marker)){
   if(width||length<8)fail();height=b.readUInt16BE(offset+3);width=b.readUInt16BE(offset+5);
   if(width<1||height<1||width>240||height>240)fail();
  }else if(marker>=0xc0&&marker<=0xcf&&![0xc4,0xc8,0xcc].includes(marker))fail();
  offset+=length;
 }
 return fail();
}
