import { Module } from '@nestjs/common';
import { DatabaseService } from '../database.service';
import { AuthController } from './auth.controller';
import { AuthService } from './auth.service';
import { PasswordService } from './password.service';
import { AccountMailer, LocalAccountMailer } from './mail';
import { AuthRateLimit } from './rate-limit';
import { SessionGuard } from './session.guard';

@Module({ controllers: [AuthController], providers: [DatabaseService, AuthService, PasswordService, AuthRateLimit, SessionGuard, { provide: AccountMailer, useClass: LocalAccountMailer }], exports: [SessionGuard, AuthService] })
export class AuthModule {}
