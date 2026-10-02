import { Module } from '@nestjs/common';
import { DatabaseService } from './database.service';
import { HealthController } from './health.controller';
import { AuthModule } from './auth/auth.module';
import { UploadModule } from './uploads/upload.module';

@Module({ imports: [AuthModule, UploadModule], controllers: [HealthController], providers: [DatabaseService] })
export class AppModule {}
