import { DatabaseService } from '../src/database.service';
import { Pool } from 'pg';
jest.mock('pg', () => ({ Pool: jest.fn() }));

describe('DatabaseService', () => {
  const query = jest.fn();
  const end = jest.fn().mockResolvedValue(undefined);
  const on = jest.fn();
  let originalUrl: string | undefined;
  beforeEach(() => {
    originalUrl = process.env.DATABASE_URL;
    process.env.DATABASE_URL = 'postgresql://test_user:test_secret@localhost/test_db';
    (Pool as unknown as jest.Mock).mockImplementation(() => ({ query, end, on }));
  });
  afterEach(() => {
    if (originalUrl === undefined) delete process.env.DATABASE_URL;
    else process.env.DATABASE_URL = originalUrl;
    jest.clearAllMocks();
  });
  it('performs a real query through the pool interface', async () => {
    query.mockResolvedValue({ rows: [{ value: 1 }] });
    const service = new DatabaseService();
    expect(await service.isReachable()).toBe(true);
    expect(query).toHaveBeenCalledWith('SELECT 1');
    await service.onApplicationShutdown();
    expect(end).toHaveBeenCalled();
  });
  it('contains database errors and never logs credentials', async () => {
    query.mockRejectedValue(new Error('postgresql://test_user:test_secret@localhost/test_db'));
    const log = jest.spyOn(console, 'error').mockImplementation(() => {});
    expect(await new DatabaseService().isReachable()).toBe(false);
    expect(log).not.toHaveBeenCalled();
    log.mockRestore();
  });
  it('requires explicit database configuration', () => {
    delete process.env.DATABASE_URL;
    expect(() => new DatabaseService()).toThrow('DATABASE_URL is required');
  });
});
