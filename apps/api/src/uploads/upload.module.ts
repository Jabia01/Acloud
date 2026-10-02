import { Module } from '@nestjs/common';
import { AuthModule } from '../auth/auth.module';
import { DatabaseService } from '../database.service';
import { UploadController } from './upload.controller';
import { UploadService } from './upload.service';
import { ObjectStorageProvider,S3ObjectStorageProvider } from './storage';
@Module({imports:[AuthModule],controllers:[UploadController],providers:[DatabaseService,UploadService,{provide:ObjectStorageProvider,useClass:S3ObjectStorageProvider}]})
export class UploadModule {}
