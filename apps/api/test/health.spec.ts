import 'reflect-metadata';
import { Test } from '@nestjs/testing';
import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { AppModule } from '../src/app.module';
import { DatabaseService } from '../src/database.service';

describe('GET /health', () => {
  let app: INestApplication;
  const database = { isReachable: jest.fn() };
  beforeAll(async () => {
    const module = await Test.createTestingModule({ imports: [AppModule] })
      .overrideProvider(DatabaseService).useValue(database).compile();
    app = module.createNestApplication();
    await app.init();
  });
  afterAll(async () => { await app.close(); });

  it('reports API and reachable database with HTTP 200', async () => {
    database.isReachable.mockResolvedValue(true);
    const response = await request(app.getHttpServer()).get('/health').expect(200);
    expect(response.body).toEqual({ status: 'ok', checks: { api: 'up', database: 'up' } });
    expect(response.headers['cache-control']).toBe('no-store');
  });

  it('reports unreachable database with HTTP 503, without infrastructure information', async () => {
    database.isReachable.mockResolvedValue(false);
    const response = await request(app.getHttpServer()).get('/health').expect(503);
    expect(response.body).toEqual({ status: 'degraded', checks: { api: 'up', database: 'down' } });
    expect(JSON.stringify(response.body)).not.toMatch(/password|postgres|localhost|connection|credential|stack/i);
  });
});
