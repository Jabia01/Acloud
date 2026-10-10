import {StaffMFAService} from '../hardening/staff-mfa';
import {Module} from '@nestjs/common';
import {DatabaseService} from '../database.service';
import {PasswordService} from '../auth/password.service';
import {UploadModule} from '../uploads/upload.module';
import {AdminController} from './controller';
import {AdminService} from './service';
import {AdminGuard,AdminRateLimit} from './guard';
@Module({imports:[UploadModule],controllers:[AdminController],providers:[StaffMFAService,DatabaseService,PasswordService,AdminService,AdminGuard,AdminRateLimit],exports:[AdminService,AdminGuard,AdminRateLimit]})
export class AdminModule{}
