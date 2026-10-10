import {DurableEmailQueue} from '../hardening/email';
import { Module } from '@nestjs/common';
import { DatabaseService } from '../database.service';
import { AuthController } from './auth.controller';
import { AuthService } from './auth.service';
import { PasswordService } from './password.service';
import { AccountMailer, LocalAccountMailer } from './mail';
import { AuthRateLimit } from './rate-limit';
import { SessionGuard } from './session.guard';

@Module({ controllers: [AuthController], providers: [DatabaseService, AuthService, PasswordService, AuthRateLimit, SessionGuard, {provide:AccountMailer,inject:[DurableEmailQueue],useFactory:(queue:DurableEmailQueue)=>process.env.NODE_ENV==='production'?queue:new LocalAccountMailer()}], exports: [SessionGuard, AuthService] })
export class AuthModule {}
