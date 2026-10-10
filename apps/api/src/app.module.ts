import {MediaManifestModule} from './media-manifests/module';
import {RestoreModule} from './restore/module';
import {BetaCoreModule,BetaModule} from './beta/module';
import {OperationsModule} from './hardening/operations';
import {HardeningModule} from './hardening/module';
import {LocalStorageModule} from './local-storage/module';
import {BillingModule} from './billing/module';
import { AdminModule } from './admin/module';
import { Module } from '@nestjs/common';
import { DatabaseService } from './database.service';
import { HealthController } from './health.controller';
import { AuthModule } from './auth/auth.module';
import { UploadModule } from './uploads/upload.module';

@Module({ imports: [MediaManifestModule,RestoreModule,BetaCoreModule,BetaModule,HardeningModule,OperationsModule,AuthModule, UploadModule,LocalStorageModule, AdminModule,BillingModule], controllers: [HealthController], providers: [DatabaseService] })
export class AppModule {}
