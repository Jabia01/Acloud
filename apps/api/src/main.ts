import {LifecycleService} from './lifecycle/service';import {lifecyclePolicy} from './lifecycle/policy';
import {BetaErrorReporter} from './beta/errors';
import {BetaPolicy} from './beta/policy';
import 'reflect-metadata';
import {validateConfiguration} from './hardening/config';
import {logEvent} from './hardening/logging';
import {randomUUID} from 'node:crypto';
import {NestExpressApplication} from '@nestjs/platform-express';
import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module';
import {ObjectStorageProvider} from './uploads/storage';
import {DatabaseService} from './database.service';
import { SafeErrors } from './auth/safe-errors';

async function bootstrap() {
  const configuration=validateConfiguration();lifecyclePolicy();
  const port = Number(process.env.API_PORT ?? 3001);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Invalid API_PORT');
  const app = await NestFactory.create<NestExpressApplication>(AppModule, { logger: false, abortOnError: false, rawBody:true,bodyParser:false });
  app.getHttpAdapter().getInstance().disable('x-powered-by');
  app.getHttpAdapter().getInstance().set('trust proxy',false);
  app.useBodyParser('json',{limit:'64kb'});
  app.useBodyParser('urlencoded',{limit:'16kb',extended:false});
  app.useGlobalFilters(new SafeErrors(app.get(BetaErrorReporter)));
  app.use((_request: any, response: { setHeader(name: string, value: string): void }, next: () => void) => {
    const correlationId=randomUUID();_request.correlationId=correlationId;response.setHeader('X-Request-ID',correlationId);if(process.env.BETA_DEPLOYMENT_FINGERPRINT)response.setHeader('X-Environment-Fingerprint',process.env.BETA_DEPLOYMENT_FINGERPRINT);
    if(configuration.production)response.setHeader('Strict-Transport-Security','max-age=31536000; includeSubDomains');
    response.setHeader('Cache-Control', 'no-store');
    response.setHeader('Referrer-Policy', 'no-referrer');
    response.setHeader('X-Content-Type-Options', 'nosniff');
    next();
  });
  if(configuration.production){if(!await app.get(DatabaseService).isReachable()||!await app.get(ObjectStorageProvider).isHealthy())throw new Error('Production dependencies unavailable');app.enableCors({origin:process.env.WEB_ORIGIN,credentials:false,allowedHeaders:['Authorization','Content-Type','Idempotency-Key','X-App-Version','X-Environment-Fingerprint'],methods:['GET','POST','DELETE'],maxAge:300});}
  await app.get(BetaPolicy).startup();
  if(configuration.production||process.env.LIFECYCLE_LEDGER_DIR)await app.get(LifecycleService).replayTombstones();
  app.enableShutdownHooks();
  await app.listen(port, '0.0.0.0');
  logEvent({code:'API_STARTED',service:'api'});
}

void bootstrap().catch(() => {
  logEvent({code:'API_STARTUP_FAILED',severity:'ERROR'});
  process.exitCode = 1;
});
