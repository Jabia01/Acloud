import { Controller, Get, Inject, Res } from '@nestjs/common';
import type { Response } from 'express';
import type { HealthResponse } from '@backup/shared';
import { DatabaseService } from './database.service';

@Controller('health')
export class HealthController {
  constructor(@Inject(DatabaseService) private readonly database: DatabaseService) {}

  @Get()
  async health(@Res({ passthrough: true }) response: Response): Promise<HealthResponse> {
    const reachable = await this.database.isReachable();
    response.status(reachable ? 200 : 503);
    response.setHeader('Cache-Control', 'no-store');
    return { status: reachable ? 'ok' : 'degraded', checks: { api: 'up', database: reachable ? 'up' : 'down' } };
  }
}
