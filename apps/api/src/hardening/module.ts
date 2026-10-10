import {DurableJobs} from './jobs';
import {DurableEmailQueue} from './email';
import {Global,Module} from '@nestjs/common';
import {SafeMetricsInterceptor} from './metrics-interceptor';
import {APP_GUARD,APP_INTERCEPTOR} from '@nestjs/core';
import {DatabaseService} from '../database.service';
import {RateLimitStore,MemoryRateLimitStore,PostgresRateLimitStore,DistributedRateLimiter,ProductionRateGuard} from './limiter';
@Global() @Module({providers:[DurableJobs,DurableEmailQueue,DatabaseService,PostgresRateLimitStore,{provide:RateLimitStore,inject:[PostgresRateLimitStore],useFactory:(db:PostgresRateLimitStore)=>{if(process.env.NODE_ENV==='production'&&process.env.RATE_LIMIT_BACKEND!=='postgres')throw new Error('Distributed limiter required');return process.env.RATE_LIMIT_BACKEND==='postgres'?db:new MemoryRateLimitStore();}},DistributedRateLimiter,{provide:APP_INTERCEPTOR,useClass:SafeMetricsInterceptor},{provide:APP_GUARD,useClass:ProductionRateGuard}],exports:[DurableJobs,DurableEmailQueue,DistributedRateLimiter,RateLimitStore]})
export class HardeningModule{}
