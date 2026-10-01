import { Module } from '@nestjs/common';
import { DatabaseService } from './database.service';
import { HealthController } from './health.controller';
import { AuthModule } from './auth/auth.module';

@Module({ imports: [AuthModule], controllers: [HealthController], providers: [DatabaseService] })
export class AppModule {}
