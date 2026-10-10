import {Module} from '@nestjs/common';
import {AuthModule} from '../auth/auth.module';
import {AdminModule} from '../admin/module';
import {DatabaseService} from '../database.service';
import {BillingProvider,PaystackBillingProvider} from './provider';
import {EntitlementService} from './entitlement';
import {BillingService} from './service';
import {BillingController,AdminBillingController,BillingRateLimit} from './controller';
@Module({imports:[AuthModule,AdminModule],controllers:[BillingController,AdminBillingController],providers:[DatabaseService,EntitlementService,BillingService,BillingRateLimit,{provide:BillingProvider,useClass:PaystackBillingProvider}],exports:[BillingService,EntitlementService,BillingProvider]})
export class BillingModule{}
