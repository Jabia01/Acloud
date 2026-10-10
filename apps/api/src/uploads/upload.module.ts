import { Module } from '@nestjs/common';
import { AuthModule } from '../auth/auth.module';
import { DatabaseService } from '../database.service';
import { UploadController } from './upload.controller';
import { UploadService } from './upload.service';
import { ObjectStorageProvider,createStorageProvider } from './storage';
@Module({imports:[AuthModule],controllers:[UploadController],providers:[DatabaseService,UploadService,{provide:ObjectStorageProvider,useFactory:createStorageProvider}],exports:[UploadService,ObjectStorageProvider]})
export class UploadModule {}
