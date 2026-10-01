import 'reflect-metadata';
import { NestFactory } from '@nestjs/core';
import { AppModule } from './app.module';
import { SafeErrors } from './auth/safe-errors';

async function bootstrap() {
  const port = Number(process.env.API_PORT ?? 3001);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Invalid API_PORT');
  const app = await NestFactory.create(AppModule, { logger: false, abortOnError: false });
  app.getHttpAdapter().getInstance().disable('x-powered-by');
  app.useGlobalFilters(new SafeErrors());
  app.use((_request: unknown, response: { setHeader(name: string, value: string): void }, next: () => void) => {
    response.setHeader('Cache-Control', 'no-store');
    response.setHeader('Referrer-Policy', 'no-referrer');
    response.setHeader('X-Content-Type-Options', 'nosniff');
    next();
  });
  app.enableShutdownHooks();
  await app.listen(port, '0.0.0.0');
  console.info(`Development API listening on port ${port}`);
}

void bootstrap().catch(() => {
  console.error('API startup failed. Check local configuration and dependencies.');
  process.exitCode = 1;
});
